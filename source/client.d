module mcyeti.client;

import std.file;
import std.json;
import std.path;
import std.zlib;
import std.ascii;
import std.array;
import std.stdio;
import std.format;
import std.socket;
import std.bitmanip;
import std.datetime;
import std.algorithm;
import std.digest.md;
import std.datetime.stopwatch;
import mcyeti.app;
import mcyeti.util;
import mcyeti.types;
import mcyeti.world;
import mcyeti.server;
import mcyeti.player;
import mcyeti.blockdb;
import mcyeti.protocol;
import mcyeti.commandManager;
import mcyeti.cpe.support;

alias MarkCallback = void function(Client, Server, void*);

struct ClipboardItem {
	ushort x;
	ushort y;
	ushort z;
	ushort block;
}

class Client : Player {
	Socket          socket;
	bool            authenticated;
	ubyte[]         inBuffer;
	ubyte[]         outBuffer;
	World           world;
	Vec3!ushort[]   marks;
	uint            marksWaiting;
	MarkCallback    markCallback;
	ushort          markBlock;
	void*           markInfo;
	ClipboardItem[] clipboard;
	ubyte           messagesSent;
	StopWatch       automuteTimer;

	bool     cpeSupported;
	string[] cpeExtensions;
	uint     cpeExtAmount;
	
	private Vec3!float pos;
	private Dir3D      direction;
	private string     clientName;   

	this(Socket psocket, Server server) {
		socket = psocket;
		ip     = socket.remoteAddress.toAddrString();
	}

	private void SendExtensions() {
		auto extInfo           = new Bi_ExtInfo();
		extInfo.appName        = appVersion;
		extInfo.extensionCount = 0;

		outBuffer ~= extInfo.CreateData();

		foreach (ref ext ; supportedExtensions) {
			auto entry       = new Bi_ExtEntry();
			entry.name       = ext.name;
			entry.extVersion = ext.extVersion;

			outBuffer ~= entry.CreateData();
		}
	}

	string GetClientName() {
		return cpeSupported? clientName : "Minecraft Classic";
	}

	Vec3!float GetPosition() {
		return pos;
	}

	void Teleport(Vec3!float ppos) {
		auto packet = new S2C_SetPosOr();

		pos = ppos;

		packet.id      = 255;
		packet.x       = pos.x;
		packet.y       = pos.y;
		packet.z       = pos.z;
		packet.yaw     = direction.yaw;
		packet.heading = direction.heading;

		outBuffer ~= packet.CreateData();
	}

	Dir3D GetDirection() {
		return direction;
	}

	void SendMessage(string msg) {
		bool firstSend = true;
		while (msg.length > 0) {
			auto message = new S2C_Message();

			message.id       = cast(byte) 0;
			message.message  = msg[0 .. (min(64, msg.length))];
			outBuffer       ~= message.CreateData();

			msg = msg[min(64, msg.length) .. $];

			firstSend = false;
		}
	}

	bool SendData(Server server) {
		if (outBuffer.length == 0) {
			return true;
		}
	
		socket.blocking = true;

		while (outBuffer.length > 0) {
			auto len = socket.send(cast(void[]) outBuffer);

			if (len == Socket.ERROR) {
				return false;
			}

			outBuffer = outBuffer[len .. $];
		}

		socket.blocking = false;
		return true;
	}

	void SendWorld(World world, Server server, bool registerNewClient = true) {
		auto serialised = world.PackXZY();

		outBuffer ~= (new S2C_LevelInit()).CreateData();

		// add world size
		serialised = nativeToBigEndian(world.GetVolume()) ~ serialised;

		auto compressor  = new Compress(HeaderFormat.gzip);
		auto compressed  = compressor.compress(serialised);
		compressed      ~= compressor.flush();

		serialised = cast(ubyte[]) compressed;

		while (serialised.length > 0) {
			auto packet = new S2C_LevelChunk();

			packet.length = cast(short) min(serialised.length, 1024);
			packet.data   = new ubyte[1024];
			
			packet.data[0 .. packet.length] = serialised[0 .. packet.length];

			serialised = serialised[packet.length .. $];

			// get percentage
			float floatVolume = cast(float) world.GetVolume();
			float floatSent   = floatVolume - cast(float) serialised.length;
			packet.percent = cast(ubyte) ((floatSent / floatVolume) * 100.0);

			outBuffer ~= packet.CreateData();
		}

		auto endPacket = new S2C_LevelFinalise();
		endPacket.x    = world.GetSize().x;
		endPacket.y    = world.GetSize().y;
		endPacket.z    = world.GetSize().z;
		outBuffer     ~= endPacket.CreateData();

		pos = world.spawn.CastTo!float();

		if (registerNewClient) {
			world.NewClient(this, server);
		}
	}

	void Mark(uint amount, MarkCallback callback, void* info) {
		marksWaiting = amount;
		markCallback = callback;
		markInfo     = info;
		SendMessage("&eMark a block");
	}

	void SendServerIdentification(Server server, string motd) {
		auto identification = new S2C_Identification();

		if (motd == "ignored") {
			motd = server.config.motd;
		}

		identification.protocolVersion = 0x07;
		identification.serverName      = server.config.name;
		identification.motd            = motd;
		identification.userType        = 0x64;

		outBuffer ~= identification.CreateData();
	}

	void Update(Server server) {
		auto time = Clock.currTime().toUnixTime();

		if (muted && (muteTime - time < 0)) {
			SendMessage("&eYou are no longer muted");
			muted = false;
			SaveInfo();
		}

		bool notEnoughData = false;
		
		while ((inBuffer.length != 0) && !notEnoughData) {
			switch (inBuffer[0]) {
				case C2S_Identification.pid: {
					auto packet = new C2S_Identification();

					if (inBuffer.length < packet.GetSize() + 1) {
						notEnoughData = true;
						break;
					}

					inBuffer = inBuffer[1 .. $];

					packet.FromData(inBuffer);
					inBuffer = inBuffer[packet.GetSize() .. $];

					auto correctMppass = md5Of(
						server.salt ~ packet.username
					).BytesToString();

					if ((correctMppass == packet.mppass) || (ip == "127.0.0.1")) {
						username = packet.username;
					}
					else {
						server.Kick(this, "Incorrect mppass");
						return;
					}

					if (server.PlayerOnline(packet.username)) {
						server.Kick(packet.username, "Connected from another client");
					}

					if (packet.protocolVersion != 0x07) {
						server.Kick(this, "Server only supports protocol version 7");
						return;
					}

					authenticated = true;

					// check if client supports CPE
					if (packet.unused == 0x42) {
						cpeSupported = true;
						SendExtensions();
					}
					
					// set up info
					string infoPath = format(
						"%s/players/%s.json",
						dirName(thisExePath()), username
					);

					string oldIP = ip;

					if (exists(infoPath)) {
						InfoFromJSON(parseJSON(readText(infoPath)));
					}
					else {
						SaveInfo();
					}

					ip = oldIP;

					// new player info stuff
					/*if ("colour" !in info) {
						info["colour"] = "f";
					}
					if ("title" !in info) {
						info["title"] = "";
					}
					if ("nickname" !in info) {
						info["nickname"] = "";
					}
					if ("infractions" !in info) {
						info["infractions"] = cast(JSONValue[]) [];
					}
					if ("muted" !in info) {
						info["muted"] = false;
					} // TODO
					*/
					SaveInfo();

					if (banned) {
						server.Kick(this, "You're banned!");
						return;
					}

					if (muted) {
						SendMessage("&eYou are muted");
					}

					server.SendGlobalMessage(
						format("&a+&f %s &fhas connected", GetDisplayName(true))
					);

					if (server.config.owner == username) {
						rank = 0xF0;
						SaveInfo();
					}

					SendServerIdentification(server, server.config.motd);

					if (!cpeSupported) {
						// send world
						server.SendPlayerToWorld(this, server.config.mainLevel);
					}
					break;
				}
				case C2S_SetBlock.pid: {
					auto packet = new C2S_SetBlock();

					if (inBuffer.length < packet.GetSize() + 1) {
						notEnoughData = true;
						break;
					}

					inBuffer = inBuffer[1 .. $];

					packet.FromData(inBuffer);
					inBuffer = inBuffer[packet.GetSize() .. $];

					if (world is null) {
						break;
					}

					auto pos = Vec3!ushort(packet.x, packet.y, packet.z);

					bool resetBlock = false;

					if (rank < world.GetPermissionBuild()) {
						SendMessage("&cYou can't build here");
						resetBlock = true;
					}

					if (marksWaiting > 0) {
						-- marksWaiting;

						marks      ~= pos;
						resetBlock  = true;
						markBlock   = packet.blockType;

						if (marksWaiting > 0) {
							SendMessage("&eMark a block");
						}
						else {
							if (markCallback) {
								markCallback(this, server, markInfo);
								marksWaiting = 0;
								markCallback = null;
								markBlock    = 0;
								marks        = [];
							}
							else {
								SendMessage("&eWarning: no mark callback set");
							}
						}
					}

					if (resetBlock) {
						auto resetPacket  = new S2C_SetBlock();
						resetPacket.x     = packet.x;
						resetPacket.y     = packet.y;
						resetPacket.z     = packet.z;
						resetPacket.block = world.GetBlock(packet.x, packet.y, packet.z);

						outBuffer ~= resetPacket.CreateData();
						break;
					}

					auto oldBlock = world.GetBlock(packet.x, packet.y, packet.z);

					ubyte blockType;
					if (packet.mode == 0x01) { // created
						blockType = packet.blockType;
					}
					else { // destroyed
						blockType = Block.Air;
					}
					world.SetBlock(packet.x, packet.y, packet.z, blockType);

					// save to BlockDB
					auto blockdb = new BlockDB(world.GetName());

					auto entry = BlockEntry(
						username,
						packet.x,
						packet.y,
						packet.z,
						blockType,
						oldBlock,
						Clock.currTime().toUnixTime(),
						""
					);

					blockdb.AppendEntry(entry);
					break;
				}
				case C2S_Position.pid: {
					auto packet = new C2S_Position();

					if (inBuffer.length < packet.GetSize() + 1) {
						notEnoughData = true;
						break;
					}

					inBuffer = inBuffer[1 .. $];

					if (world is null) {
						break;
					}

					packet.FromData(inBuffer);
					inBuffer = inBuffer[packet.GetSize() .. $];

					pos.x             = packet.x;
					pos.y             = packet.y;
					pos.z             = packet.z;
					direction.yaw     = packet.yaw;
					direction.heading = packet.heading;

					auto packetOut = new S2C_SetPosOr();

					packetOut.id      = world.GetClientID(this);
					packetOut.x       = pos.x;
					packetOut.y       = pos.y;
					packetOut.z       = pos.z;
					packetOut.yaw     = direction.yaw;
					packetOut.heading = direction.heading;

					foreach (key, value ; world.clients) {
						if ((value is null) || (value is this)) {
							continue;
						}

						value.outBuffer ~= packetOut.CreateData();
					}
					break;
				}
				case C2S_Message.pid: {
					auto packet = new C2S_Message();

					if (inBuffer.length < packet.GetSize() + 1) {
						notEnoughData = true;
						break;
					}

					inBuffer = inBuffer[1 .. $];

					packet.FromData(inBuffer);
					inBuffer = inBuffer[packet.GetSize() .. $];

					if (muted) {
						SendMessage("&eYou are muted");
						return;
					}

					string colourCodes = "0123456789abcdef";
					char[] msg         = cast(char[]) packet.message;
					for (size_t i = 0; i < msg.length - 1; ++ i) {
						if (
							(msg[i] == '%') &&
							colourCodes.canFind(msg[i + 1])
						) {
							msg[i] = '&';
						}
					}
					packet.message = cast(string) msg;

					if (!authenticated) {
						break;
					}

					if (packet.message[0] == '/') {
						Log("%s used %s", username, packet.message);

						auto parts = packet.message[1 .. $].split!isWhite();

						if (parts.length == 0) {
							break;
						}

						if (!server.commands.CommandExists(parts[0])) {
							SendMessage("&cNo such command");
							return;
						}

						if (!server.commands.CanRunCommand(parts[0], this)) {
							SendMessage("&cYou can't run this command");
							break;
						}

						try {
							server.commands.RunCommand(
								parts[0], server, this, parts[1 .. $]
							);
						}
						catch (CommandException e) {
							SendMessage(format("&c%s", e.msg));
						}
						break;
					}


					auto message = format(
						"%s: &f%s", GetDisplayName(true), packet.message
					);
					server.SendGlobalMessage(message);
					break;
				}
				////////////////////////////////////////////
				//                   CPE                  //
				////////////////////////////////////////////
				// Abandon all hope all ye who enter here //
				////////////////////////////////////////////
				case Bi_ExtInfo.pid: {
					auto packet = new Bi_ExtInfo();

					if (inBuffer.length < packet.GetSize() + 1) {
						notEnoughData = true;
						break;
					}

					inBuffer = inBuffer[1 .. $];

					packet.FromData(inBuffer);
					inBuffer = inBuffer[packet.GetSize() .. $];

					clientName = packet.appName;

					cpeExtAmount = packet.extensionCount;
					break;
				}
				case Bi_ExtEntry.pid: {
					auto packet = new Bi_ExtEntry();

					if (inBuffer.length < packet.GetSize() + 1) {
						notEnoughData = true;
						break;
					}

					inBuffer = inBuffer[1 .. $];

					packet.FromData(inBuffer);
					inBuffer = inBuffer[packet.GetSize() .. $];

					Extension ext;
					bool      addExt = true;
					
					try {
						ext = GetExtension(packet.name);
					}
					catch (ProtocolException) {
						addExt = false;
					}

					if (ext.extVersion != packet.extVersion) {
						addExt = false;
					}

					if (addExt) {
						cpeExtensions ~= packet.name;
					}

					-- cpeExtAmount;
					if (cpeExtAmount == 0) {
						// send world
						server.SendPlayerToWorld(this, server.config.mainLevel);
					}
					break;
				}
				default: {
					server.Kick(this, format("Bad packet ID %X", inBuffer[0]));
					return;
				}
			}
		}
	}
}
