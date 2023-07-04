module mcyeti.commands.other;

import std.conv;
import std.file;
import std.json;
import std.path;
import std.array;
import std.format;
import std.string;
import std.algorithm;
import core.stdc.stdlib;
import mcyeti.types;
import mcyeti.world;
import mcyeti.client;
import mcyeti.server;
import mcyeti.commandManager;

class AddAliasCommand : Command {
	this() {
		name = "addalias";
		help = [
			"&a/addalias [alias name] [command]",
			"&eAdds a new alias"
		];
		argumentsRequired = 2;
		permission        = 0xE0;
		category          = CommandCategory.Other;
	}

	override void Run(Server server, Client client, string[] args) {
		server.commands.aliases[args[0]] = args[1];

		string aliasesPath = dirName(thisExePath()) ~ "/properties/aliases.json";
		std.file.write(
			aliasesPath,
			server.commands.SerialiseAliases().toPrettyString()
		);
	}
}
