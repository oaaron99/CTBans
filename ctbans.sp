#include <sourcemod>
#include <addicted>

#define CHAT_PREFIX "{green}[ {red}LG{green} ] {default}"

enum BanHandler {

	iCount,
	iCreated,
	iLength,
	iTimeLeft,
	String:sAdmin[64],
	String:sReason[120],

}

Handle g_hDB = null;

char g_sRestrictedSound[] = "buttons/button11.wav";

int g_iBanInfo[MAXPLAYERS+1][BanHandler];

public Plugin myinfo = {

	name = "CT Bans",
	author = "Addicted",
	version = "1.0",
	url = "oaaron.com"

};

public void OnPluginStart() {

	// Intial Database
	DatabaseConnect();

	// Hook Events
	AddCommandListener(Event_OnJoinTeam, "jointeam");

	// Admin Commands
	RegAdminCmd("sm_ctban", CMD_CTBan, ADMFLAG_BAN);
	
}

public void DatabaseConnect() {

	g_hDB = null;

	if (!SQL_CheckConfig("ctbans")) {

		SetFailState("Can't find 'ctbans' entry in sourcemod/configs/databases.cfg");

	}

	SQL_TConnect(OnDatabaseConnected, "ctbans");

}

// [ DATABASE STUFF ] //

public void OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data) {

	if (hndl == null) {

		SetFailState("Failed to connect, SQL Error:  %s", error);
		return;

	}

	g_hDB = hndl;

	int len = 0;
	char query[512];
	len += Format(query[len], sizeof(query)-len, "CREATE TABLE IF NOT EXISTS `ctbans` (");
	len += Format(query[len], sizeof(query)-len, " `id` INT(12) NOT NULL AUTO_INCREMENT,");
	len += Format(query[len], sizeof(query)-len, " `perp_steamid` VARCHAR(64) NOT NULL,");
	len += Format(query[len], sizeof(query)-len, " `admin_steamid` VARCHAR(64) NOT NULL,");
	len += Format(query[len], sizeof(query)-len, " `admin_steamid` VARCHAR(64) NOT NULL,");
	len += Format(query[len], sizeof(query)-len, " `admin_name` VARCHAR(32) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT 'undefined' ,");
	len += Format(query[len], sizeof(query)-len, " `created` INT(18) NOT NULL,");
	len += Format(query[len], sizeof(query)-len, " `length` INT(18) NOT NULL,");
	len += Format(query[len], sizeof(query)-len, " `timeleft` INT(18) NOT NULL,");
	len += Format(query[len], sizeof(query)-len, " `reason` VARCHAR(120) NOT NULL DEFAULT 'Breaking Rules',");
	len += Format(query[len], sizeof(query)-len, " `removed` VARCHAR(3) NOT NULL DEFAULT 'N',");
	len += Format(query[len], sizeof(query)-len, " PRIMARY KEY (`id`), ");
	len += Format(query[len], sizeof(query)-len, " UNIQUE INDEX `id` (`id`))");
	len += Format(query[len], sizeof(query)-len, " COLLATE='utf8_general_ci' ENGINE=MyISAM; ");
	//SQL_TQuery(g_hDB, SQL_ErrorCheckCallback, query);

	LoopValidPlayers(i) {

		OnClientPostAdminCheck(i);

	}

}

public void SQL_ErrorCheckCallback(Handle owner, Handle hndl, const char[] error, any data) {

	if (!StrEqual("", error)) {

		LogError("(SQL_ErrorCheckCallback) SQL Error: %s", error);
	
	}

}

public void GetCTBanData(Handle owner, Handle hndl, const char[] error, any userid) {

	int client = GetClientOfUserId(userid);

	if (!IsValidClient(client)) {

		return;

	}

	if (owner == null || hndl == null) {

		LogError("(GetCTBanData) Query failed for client '%N': %s", client, error);
		return;

	}

	if (!SQL_FetchRow(hndl)) {

		return;

	}

	//g_iBanInfo[client][iCount] = SQL_FetchInt(hndl, 0);
	g_iBanInfo[client][iCreated] = SQL_FetchInt(hndl, 0);
	g_iBanInfo[client][iLength] = SQL_FetchInt(hndl, 1);
	g_iBanInfo[client][iTimeLeft] = SQL_FetchInt(hndl, 2);
	SQL_FetchString(hndl, 3, g_iBanInfo[client][sReason], 64);
	SQL_FetchString(hndl, 4, g_iBanInfo[client][sAdmin], 120);

	

}

public void GetCTBanCount(Handle owner, Handle hndl, const char[] error, any userid) {

	int client = GetClientOfUserId(userid);

	if (!IsValidClient(client)) {

		return;

	}

	if (owner == null || hndl == null) {

		LogError("(GetCTBanCount) Query failed for client '%N': %s", client, error);
		return;

	}

	if (!SQL_FetchRow(hndl)) {

		return;

	}

	g_iBanInfo[client][iCount] = SQL_FetchInt(hndl, 0);

	if (g_iBanInfo[client][iCount] == 0) {

		return;

	}

	LoopValidPlayers(i) {

		if (!CheckCommandAccess(i, "", ADMFLAG_GENERIC, true)) {

			continue;

		}

		CPrintToChat(i, CHAT_PREFIX ... "WARNING: {purple}%N{default} has {blue}%i{default} previous CT Bans", client, g_iBanInfo[client][iCount]);

	}

}

// [ EVENT CALLBACKS ] //

public void OnClientPostAdminCheck(int client) {

	if (!IsValidClient(client)) {

		return;

	}

	if (g_hDB == null) {

		SetFailState("Invalid database connection");
		return;

	}

	char query[512], steamid[64];
	GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));

	Format(query, sizeof(query), "SELECT `created`, `length`, `timeleft`, `reason`, `admin_name` FROM `ctbans` WHERE `perp_steamid` = '%s' AND `removed` = 'N' LIMIT 1;", steamid);
	SQL_TQuery(g_hDB, GetCTBanData, query, GetClientUserId(client), DBPrio_High);

	Format(query, sizeof(query), "SELECT COUNT(*) FROM `ctbans` WHERE `perp_steamid` = '%s'", steamid);
	SQL_TQuery(g_hDB, GetCTBanCount, query, GetClientUserId(client), DBPrio_High);

}

public Action Event_OnJoinTeam(int client, const char[] szCommand, int iArgCount) {

	if (!IsValidClient(client)) {

		return Plugin_Continue;

	}

	char teamString[2];
	GetCmdArg(1, teamString, sizeof(teamString));
	int team = StringToInt(teamString);
	
	if (team == 0) {

		ClientCommand(client, "play %s", g_sRestrictedSound);
		CPrintToChat(client, CHAT_PREFIX ... "You cannot use auto select to join a team");
		return Plugin_Handled;

	}

	if (team != CS_TEAM_CT) {

		return Plugin_Continue;

	}

	if (g_iBanInfo[client][iTimeLeft] < 1) {

		return Plugin_Continue;

	}

	ClientCommand(client, "play %s", g_sRestrictedSound);
	CPrintToChat(client, CHAT_PREFIX ... "You are currently CT Banned for {blue}%i{default} more minutes (%s)", RoundToCeil(1.0 * (g_iBanInfo[client][iTimeLeft] / 60)), g_iBanInfo[client][sReason]);

	return Plugin_Handled;

}

// [ COMMAND CALLBACKS ] //

public Action CMD_CTBan(int client, int args) {

	

}

// [ MENU HANDLERS ] //