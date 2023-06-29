module mcyeti.server;

import std.uri;
import std.file;
import std.json;
import std.path;
import std.array;
import std.stdio;
import std.format;
import std.socket;
import std.datetime;
import std.net.curl;
import std.algorithm;
import std.datetime.stopwatch;
import dauth.random;
import mcyeti.util;
import mcyeti.types;
import mcyeti.world;
import mcyeti.client;
import mcyeti.protocol;
import mcyeti.commandManager;

struct ServerConfig {
	string ip;
	ushort port;
	string heartbeatURL;
	uint   maxPlayers;
	string name;
	bool   publicServer;
	string motd;
	string owner;
}

class ServerException : Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__) {
		super(msg, file, line);
	}
}

class Server {
	bool           running;
	ServerConfig   config;
	Socket         socket;
	SocketSet      serverSet;
	SocketSet      clientSet;
	Client[]       clients;
	ulong          ticks;
	StopWatch      uptime;
	World[]        worlds;
	CommandManager commands;
	string         salt;
	JSONValue      ranks;

	this() {
		running             = true;
		config.ip           = "0.0.0.0";
		config.port         = 25565;
		config.heartbeatURL = "https://www.classicube.net/server/heartbeat";
		config.maxPlayers   = 50;
		config.name         = "[MCYeti] Default";
		config.publicServer = true;
		config.motd         = "Welcome!";

		string configPath = dirName(thisExePath()) ~ "/properties/server.json";
		
		if (exists(configPath)) {
			LoadConfig();
		}
		else {
			std.file.write(configPath, ConfigAsJSON().toPrettyString());
		}

		string ranksPath = dirName(thisExePath()) ~ "/properties/ranks.json";

		ranks              = parseJSON("{}");
		ranks["guest"]     = 0x00;
		ranks["moderator"] = 0xD0;
		ranks["admin"]     = 0xE0;
		ranks["owner"]     = 0xF0;

		if (exists(ranksPath)) {
			ranks = parseJSON(readText(ranksPath));
		}
		else {
			std.file.write(ranksPath, ranks.toPrettyString());
		}

		// generate salt
		salt = randomSalt(16).BytesToString();

		serverSet = new SocketSet();
		clientSet = new SocketSet();

		if (WorldExists("main")) {
			worlds ~= new World("main");
			worlds[$ - 1].Save();
		}
		else {
			worlds ~= new World(Vec3!ushort(64, 64, 64), "main");
			worlds[$ - 1].GenerateFlat();
			worlds[$ - 1].Save();
		}

		commands = new CommandManager();
	}

	~this() {
		if (socket) {
			socket.close();
		}
	}

	private void RunHeartbeat() {
		string url = format(
		    "%s?name=%s&port=%d&users=%d&max=%d&salt=%s&public=%s&server=MCYeti",
		    config.heartbeatURL,
		    encodeComponent(config.name),
		    config.port,
		    GetConnectedIPs(),
		    config.maxPlayers,
		    salt,
		    config.publicServer? "true" : "false"
		);

		static string oldServerURL;
		string        serverURL;

		try {
			serverURL = cast(string) get(url);
		}
		catch (CurlException e) {
			writefln("Error in heartbeat: %s", e.msg);
		}

		if (serverURL != oldServerURL) {
			writefln("Server URL: %s", serverURL);
		}

		oldServerURL = serverURL;
	}

	void Init() {
		socket          = new Socket(AddressFamily.INET, SocketType.STREAM);
		socket.blocking = false; // single-threaded server
		socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);

		version (Posix) {
			socket.setOption(
				SocketOptionLevel.SOCKET, cast(SocketOption) SO_REUSEPORT, 1
			);
		}

		socket.bind(new InternetAddress(config.ip, config.port));
		socket.listen(50);

		uptime.start();

		writefln("Listening at %s:%d", config.ip, config.port);
	}

	JSONValue ConfigAsJSON() {
		JSONValue ret = parseJSON("{}");

		ret["ip"]           = config.ip;
		ret["port"]         = cast(int) config.port;
		ret["heartbeatURL"] = config.heartbeatURL;
		ret["maxPlayers"]   = cast(int) config.maxPlayers;
		ret["name"]         = config.name;
		ret["publicServer"] = config.publicServer;
		ret["motd"]         = config.motd;
		ret["owner"]        = config.owner;

		return ret;
	}

	void LoadConfig() {
		string path = dirName(thisExePath()) ~ "/properties/server.json";
		auto   json = readText(path).parseJSON();

		config.ip           = json["ip"].str;
		config.port         = cast(ushort) json["port"].integer;
		config.heartbeatURL = json["heartbeatURL"].str;
		config.maxPlayers   = cast(uint) json["maxPlayers"].integer;
		config.name         = json["name"].str;
		config.publicServer = json["publicServer"].boolean;
		config.motd         = json["motd"].str;
		config.owner        = json["owner"].str;
	}

	ubyte GetRank(string name) {
		if (name !in ranks) {
			throw new ServerException("No such rank");
		}
	
		return cast(ubyte) ranks[name].integer;
	}

	string GetRankName(ubyte id) {
		foreach (key, value ; ranks.object) {
			if (value.integer == id) {
				return key;
			}
		}

		throw new ServerException("No such rank");
	}

	bool RankExists(string name) {
		return name in ranks? true : false;
	}

	uint GetConnectedIPs() {
		string[] ips;

		foreach (client ; clients) {
			if (client.authenticated && !ips.canFind(client.ip)) {
				ips ~= client.ip;
			}
		}

		return cast(uint) ips.length;
	}

	bool WorldExists(string name) {
		string worldPath = dirName(thisExePath()) ~ "/worlds/" ~ name ~ ".ylv";

		return exists(worldPath);
	}

	bool WorldLoaded(string name) {
		foreach (ref world ; worlds) {
			if (world.GetName() == name) {
				return true;
			}
		}

		return false;
	}

	void LoadWorld(string name) {
		if (!WorldExists(name)) {
			throw new ServerException("No such world");
		}
	
		worlds ~= new World(name);
		worlds[$ - 1].Save();
	}

	World GetWorld(string name) {
		foreach (ref world ; worlds) {
			if (world.GetName() == name) {
				return world;
			}
		}

		throw new ServerException("No such world");
	}

	bool PlayerOnline(string username) {
		foreach (ref client ; clients) {
			if (client.authenticated && (client.username == username)) {
				return true;
			}
		}

		return false;
	}

	void SendGlobalMessage(string message) {
		/*auto packet    = new S2C_Message();
		packet.id      = 0x00;
		packet.message = message;

		foreach (ref client ; clients) {
			if (client.authenticated) {
				client.outBuffer ~= packet.CreateData();
			}
		}*/

		foreach (ref client ; clients) {
			if (client.authenticated) {
				client.SendMessage(message);
			}
		}

		writeln(message.CleanString());
	}

	void Kick(string username, string message) {
		foreach (ref client ; clients) {
			if (client.authenticated && (client.username == username)) {
				Kick(client, message);
				return;
			}
		}

		throw new ServerException(format("Player %s not online", username));
	}

	void Kick(Client client, string message) {
		auto packet       = new S2C_Disconnect();
		packet.message    = message;
		client.outBuffer ~= packet.CreateData();
		client.SendData(this);
		foreach (i, ref clienti ; clients) {
			if (clienti is client) {
				clients = clients.remove(i);
				break;
			}
		}
		
		if (client.authenticated) {
			string msg = message == ""?
				format("&c-&f %s disconnected (%s)", client.username, message) :
				format("&c-&f %s disconnected", client.username);
		
			SendGlobalMessage(msg);
		}

		if (client.world) {
			client.world.RemoveClient(client);
		}
	}

	void KickIPs(string ip, string message) {
		foreach (ref client ; clients) {
			if (client.ip == ip) {
				Kick(client, message);
				KickIPs(ip, message);
				return;
			}
		}
	}

	void UnloadEmptyWorlds() {
		foreach (i, ref world ; worlds) {
			if (world.clients.length == 0) {
				worlds = worlds.remove(i);
				UnloadEmptyWorlds();
				return;
			}
		}
	}

	void SendPlayerToWorld(Client client, string worldName) {
		if (client.world) {
			client.world.RemoveClient(client);
		}
	
		foreach (ref world ; worlds) {
			if (world.GetName() == worldName) {
				client.SendMessage(format("&eSending you to &f%s", worldName));
				client.SendData(this);
				client.SendWorld(world, this);
				client.world = world;
				UnloadEmptyWorlds();
			}
		}
	}

	void SaveAll() {
		foreach (ref world ; worlds) {
			world.Save();
		}
	}

	JSONValue GetPlayerInfo(string username) {
		string infoPath = format(
			"%s/players/%s.json",
			dirName(thisExePath()), username
		);

		if (!exists(infoPath)) {
			throw new ServerException("Player not found");
		}

		return readText(infoPath).parseJSON();
	}

	Client GetPlayer(string username) {
		foreach (ref client ; clients) {
			if (client.authenticated && (client.username == username)) {
				return client;
			}
		}

		throw new ServerException("Player not found");
	}

	void SavePlayerInfo(string username, JSONValue data) {
		string infoPath = format(
			"%s/players/%s.json",
			dirName(thisExePath()), username
		);

		std.file.write(infoPath, data.toPrettyString());
	}

	void Update() {
		if (ticks % 25 == 0) {
			foreach (i, ref client ; clients) {
				auto packet = new S2C_Ping();

				client.outBuffer ~= packet.CreateData();
				if (!client.SendData(this)) {
					Kick(client, "");
					Update();
					return;
				}
			}
		}

		if (ticks % 1500 == 0) {
			RunHeartbeat();
			SaveAll();
		}
	
		serverSet.reset();
		clientSet.reset();

		serverSet.add(socket);
		if (clients) {
			foreach (ref client ; clients) {
				clientSet.add(client.socket);
			}
		}

		bool   success = true;
		Socket newClientSocket;

		try {
			newClientSocket = socket.accept();
		}
		catch (SocketAcceptException) {
			success = false;
		}

		if (success) {
			Client newClient = new Client(newClientSocket);

			newClient.socket.blocking = false;

			auto bannedIPs = readText(
				dirName(thisExePath()) ~ "/banned_ips.txt"
			).split("\n");

			if (bannedIPs.canFind(newClient.ip)) {
				auto packet = new S2C_Disconnect();

				packet.message = "You're banned!";

				newClient.outBuffer ~= packet.CreateData();
				newClient.SendData(this);
			} 
			else {
				clients ~= newClient;
				clientSet.add(newClient.socket);

				writefln("%s connected", newClient.ip);
			}
		}

		// in
		foreach (i, ref client ; clients) {
			if (!clientSet.isSet(client.socket)) {
				continue;
			}

			ubyte[] incoming = new ubyte[1024];

			long received = client.socket.receive(incoming);

			if ((received <= 0) || (received == Socket.ERROR)) {
				continue;
			}

			incoming         = incoming[0 .. received];
			client.inBuffer ~= incoming;
		}

		// out
		foreach (i, ref client ; clients) {
			auto len = clients.length;

			if (!client.SendData(this)) {
				Kick(client, "");
				//clients = clients.remove(i);
				Update();
				return;
			}
		
			client.Update(this);
					
			if (len != clients.length) {
				Update();
				return;
			}
		}
		
		++ ticks;
	}
}
