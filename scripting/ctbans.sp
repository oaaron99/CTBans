#include <sourcemod>
#include <colors_csgo>
#include <emitsoundany>
#include <ctbans>

#define PRISONER_TEAM 2
#define GUARD_TEAM 3

enum BanHandler {

	iID,
	iCount,
	iCreated,
	iLength,
	iTimeLeft,
	String:sAdmin[64],
	String:sReason[120],

}

Handle g_hDB = null;
Handle g_hCTBanTracker[MAXPLAYERS+1];

ArrayList g_RageBans[3] = {null, ...};
ArrayList g_aReasons = null;

ConVar g_cChatPrefix = null;
ConVar g_cBlockSound = null;
ConVar g_cRageLength = null;

char g_sReasonsPath[PLATFORM_MAX_PATH];
char g_sBlockSound[PLATFORM_MAX_PATH];
char g_sChatPrefix[32];

bool g_bAuthorized[MAXPLAYERS+1];
bool g_bFirstSpawn[MAXPLAYERS+1];

int g_iBanInfo[MAXPLAYERS+1][BanHandler];

int g_iRageLength;

public Plugin myinfo = {

	name = "CT Bans",
	author = "Addicted",
	version = "1.5",
	url = "addict.services"

};

public void OnPluginStart() {

	// Intial Database
	DatabaseConnect();

	// Hook Events
	AddCommandListener(Event_OnJoinTeam, "jointeam");
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_spawn", Event_PlayerSpawn);

	// Player Commands
	RegConsoleCmd("sm_isbanned", CMD_IsBanned);

	// Admin Commands
	RegAdminCmd("sm_ctban", CMD_CTBan, ADMFLAG_BAN);
	RegAdminCmd("sm_unctban", CMD_UnCTBan, ADMFLAG_BAN);
	RegAdminCmd("sm_offlinectban", CMD_OfflineCTBan, ADMFLAG_BAN);
	RegAdminCmd("sm_ragectban", CMD_RageCTBan, ADMFLAG_BAN);

	// Create ConVars
	g_cChatPrefix = CreateConVar("ctbans_chat_prefix", "[SM] ", "Chat prefix to use for all messages (Include space at end)"); 
	g_cBlockSound = CreateConVar("ctbans_block_sound", "buttons/button11.wav", "Sound to play to player when denied CT entry (Default included in CS:GO)");
	g_cRageLength = CreateConVar("ctbans_rage_length", "10", "Amount of minutes to keep a player in the rage ct ban menu", _, true, 1.0);

	AutoExecConfig(true, "ctbans");

	g_cChatPrefix.AddChangeHook(OnConVarChanged);
	g_cRageLength.AddChangeHook(OnConVarChanged);

	g_cChatPrefix.GetString(g_sChatPrefix, sizeof(g_sChatPrefix));
	g_cBlockSound.GetString(g_sBlockSound, sizeof(g_sBlockSound));
	g_iRageLength = g_cRageLength.IntValue;

	// Create Rage Ban Arrays
	g_RageBans[0] = new ArrayList();
	g_RageBans[1] = new ArrayList(ByteCountToCells(64));
	g_RageBans[2] = new ArrayList(ByteCountToCells(MAX_NAME_LENGTH));

	// Create Reasons Array
	g_aReasons = new ArrayList(ByteCountToCells(120));

	// Load Reasons
	BuildPath(Path_SM, g_sReasonsPath, sizeof(g_sReasonsPath), "configs/ctbans_reasons.txt");

	if (!FileExists(g_sReasonsPath)) {

		SetFailState("Can't find config file 'ctbans_reasons.txt' in sourcemod/configs");

	}

	LoadReasons();

	// Load Translations
	LoadTranslations("common.phrases");

}

// [ NATIVES ] //

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {

	// Register Natives
	CreateNative("CTBans_IsCTBanned", Native_IsCTBanned);

	// Register Library
	RegPluginLibrary("CTBans");

	return APLRes_Success;

}

public int Native_IsCTBanned(Handle plugin, int numParams) {

	int client = GetNativeCell(1);

	if (!IsValidClient(client)) {

		return false;

	}

	if (g_iBanInfo[client][iTimeLeft] > -1) {

		return true;

	}

	return false;

}

// [ DATABASE STUFF ] //

public void DatabaseConnect() {

	g_hDB = null;

	if (!SQL_CheckConfig("ctbans")) {

		SetFailState("Can't find 'ctbans' entry in sourcemod/configs/databases.cfg");

	}

	SQL_TConnect(OnDatabaseConnected, "ctbans");

}

public void OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data) {

	if (hndl == null) {

		SetFailState("Failed to connect, SQL Error:  %s", error);
		return;

	}

	g_hDB = hndl;

	char query[512];
	Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS `ctbans` (");
	Format(query, sizeof(query), "%s `id` INT(12) NOT NULL AUTO_INCREMENT,", query);
	Format(query, sizeof(query), "%s `perp_steamid` VARCHAR(64) NOT NULL,", query);
	Format(query, sizeof(query), "%s `admin_steamid` VARCHAR(64) NOT NULL,", query);
	Format(query, sizeof(query), "%s `admin_name` VARCHAR(64) NOT NULL,", query);
	Format(query, sizeof(query), "%s `created` INT(18) NOT NULL,", query);
	Format(query, sizeof(query), "%s `length` INT(18) NOT NULL,", query);
	Format(query, sizeof(query), "%s `timeleft` INT(18) NOT NULL,", query);
	Format(query, sizeof(query), "%s `reason` VARCHAR(120) NOT NULL DEFAULT 'Breaking Rules',", query);
	Format(query, sizeof(query), "%s `removed` VARCHAR(3) NOT NULL DEFAULT 'N',", query);
	Format(query, sizeof(query), "%s PRIMARY KEY (`id`),", query);
	Format(query, sizeof(query), "%s UNIQUE INDEX `id` (`id`))", query);
	Format(query, sizeof(query), "%s COLLATE='utf8_general_ci' ENGINE=MyISAM;", query);
	SQL_TQuery(g_hDB, SQL_ErrorCheckCallback, query);

	for (int i = 1; i <= MaxClients; i++) {
	
		if (!IsValidClient(i)) {
	
			continue;
	
		}
	
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

	g_bAuthorized[client] = true;

	if (!SQL_FetchRow(hndl)) {

		return;

	}

	g_iBanInfo[client][iID] = SQL_FetchInt(hndl, 0);
	g_iBanInfo[client][iCreated] = SQL_FetchInt(hndl, 1);
	g_iBanInfo[client][iLength] = SQL_FetchInt(hndl, 2);
	g_iBanInfo[client][iTimeLeft] = SQL_FetchInt(hndl, 3);
	SQL_FetchString(hndl, 4, g_iBanInfo[client][sReason], 64);
	SQL_FetchString(hndl, 5, g_iBanInfo[client][sAdmin], 120);

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

	for (int i = 1; i <= MaxClients; i++) {
	
		if (!IsValidClient(i)) {
	
			continue;
	
		}

		if (!CheckCommandAccess(i, "", ADMFLAG_GENERIC, true)) {

			continue;

		}

		CPrintToChat(i, "%sWARNING: {purple}%N{default} has {blue}%i{default} previous CT Ban%s", g_sChatPrefix, client, g_iBanInfo[client][iCount], g_iBanInfo[client][iCount] == 1 ? "" : "s");

	}

}

// [ EVENT CALLBACKS ] //

public void OnMapStart() {

	for (int i = 0; i < 3; i++) {

		g_RageBans[i].Clear();

	}

	for (int i = 1; i <= MaxClients; i++) {
	
		if (!IsValidClient(i)) {
	
			continue;
	
		}

		ResetPlayer(i);

	}

	PrecacheSoundAny(g_sBlockSound, true);

}

public void OnClientPostAdminCheck(int client) {

	if (!IsValidClient(client)) {

		return;

	}

	if (g_hDB == null) {

		SetFailState("Invalid database connection");
		return;

	}

	ResetPlayer(client);

	char query[512], steamid[64];
	GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));

	int userid = GetClientUserId(client);

	Format(query, sizeof(query), "SELECT `id`, `created`, `length`, `timeleft`, `reason`, `admin_name` FROM `ctbans` WHERE `perp_steamid` = '%s' AND `removed` = 'N' LIMIT 1;", steamid);
	SQL_TQuery(g_hDB, GetCTBanData, query, userid, DBPrio_High);

	Format(query, sizeof(query), "SELECT COUNT(*) FROM `ctbans` WHERE `perp_steamid` = '%s'", steamid);
	SQL_TQuery(g_hDB, GetCTBanCount, query, userid, DBPrio_Low);

	for (int i = 0; i < g_RageBans[0].Length; i++) {

		if (userid != g_RageBans[0].Get(i)) {

			continue;

		}

		g_RageBans[0].Erase(i);
		g_RageBans[1].Erase(i);
		g_RageBans[2].Erase(i);

		break;

	}

}

public void OnClientDisconnect(int client) {

	if (!IsValidClient(client)) {

		return;

	}

	char steamid[64];
	GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));

	if (g_iBanInfo[client][iTimeLeft] > -1) {

		char query[512];
		Format(query, sizeof(query), "UPDATE `ctbans` SET `timeleft`= %i WHERE `perp_steamid` = '%s' AND `id` = %i;", g_iBanInfo[client][iTimeLeft], steamid, g_iBanInfo[client][iID]);
		SQL_TQuery(g_hDB, SQL_ErrorCheckCallback, query, _, DBPrio_Low);

	} else {

		bool found = false;
		for (int i = 0; i < g_RageBans[0].Length; i++) {

			if (GetClientUserId(client) != g_RageBans[0].Get(i)) {

				continue;

			}		

			found = true;
			break;

		}

		if (!found) {

			char name[MAX_NAME_LENGTH];

			g_RageBans[0].Push(GetClientUserId(client));
			g_RageBans[1].PushString(steamid);
			g_RageBans[2].PushString(name);			

			CreateTimer(g_iRageLength * 60.0, RemoveRageInfo_Timer,  GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

		}

	}

	ResetPlayer(client);

}

public Action Event_OnJoinTeam(int client, const char[] szCommand, int iArgCount) {

	if (!IsValidClient(client)) {

		return Plugin_Continue;

	}

	char teamString[2];
	GetCmdArg(1, teamString, sizeof(teamString));
	int team = StringToInt(teamString);

	if (team != GUARD_TEAM) {

		return Plugin_Continue;

	}

	if (team == 0) {

		PlayBlockSound(client);
		CPrintToChat(client, "%sYou cannot use auto select to join a team", g_sChatPrefix);
		return Plugin_Handled;

	}

	if (g_iBanInfo[client][iTimeLeft] < 0) {

		return Plugin_Continue;

	}	

	if (!g_bAuthorized[client]) {

		PlayBlockSound(client);
		CPrintToChat(client, "%sYour CT Ban data has not been retrieved yet", g_sChatPrefix);
		return Plugin_Handled;

	}

	PlayBlockSound(client);

	char formattedLength[32], formattedTimeLeft[32];
	FormatSeconds(g_iBanInfo[client][iLength], formattedLength, sizeof(formattedLength), false);
	FormatSeconds(g_iBanInfo[client][iTimeLeft], formattedTimeLeft, sizeof(formattedTimeLeft), true);

	CPrintToChat(client, "%sYou are CT Banned %s by {purple}%s{default} for {orange}%s{default}. %s remaining", g_sChatPrefix, formattedLength, g_iBanInfo[client][sAdmin], g_iBanInfo[client][sReason], formattedTimeLeft);

	return Plugin_Handled;

}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {

	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsValidClient(client)) {

		return Plugin_Continue;

	}

	if (g_iBanInfo[client][iTimeLeft] < 1) {

		return Plugin_Continue;

	}

	if (GetClientTeam(client) == GUARD_TEAM) {

		PlayBlockSound(client);
		ChangeClientTeam(client, PRISONER_TEAM);
		return Plugin_Continue;

	}

	if (g_bFirstSpawn[client]) {

		FakeClientCommand(client, "sm_isbanned");
		g_bFirstSpawn[client] = false;

	}

	if (g_hCTBanTracker[client] != null) {

		KillTimer(g_hCTBanTracker[client]);
		g_hCTBanTracker[client] = null;

	}

	g_hCTBanTracker[client] = CreateTimer(1.0, CTBanTracker_Timer, event.GetInt("userid"), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Continue;

}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {

	if (convar == g_cChatPrefix) {

		convar.GetString(g_sChatPrefix, sizeof(g_sChatPrefix));

	}

	if (convar == g_cRageLength) {

		g_iRageLength = convar.IntValue;

	}

}

// [ COMMAND CALLBACKS ] //

public Action CMD_IsBanned(int client, int args) {

	// Accepted inputs:
	// !isbanned
	// !isbanned <player>

	int target = -1;
	if (args == 0) {

		target = client;

	} else {

		char arg1[MAX_NAME_LENGTH];
		GetCmdArg(1, arg1, sizeof(arg1));

		target = FindTarget(client, arg1, true, false);
	
	}

	if (!IsValidClient(target)) {

		CReplyToCommand(client, "%sNot a valid target", g_sChatPrefix);
		return Plugin_Handled;

	}

	if (g_iBanInfo[target][iTimeLeft] < 0) {

		CReplyToCommand(client, "%s{purple}%N{default} is not CT Banned", g_sChatPrefix, target);
		return Plugin_Handled;

	}

	char formattedLength[32], formattedTimeLeft[32];
	FormatSeconds(g_iBanInfo[client][iLength], formattedLength, sizeof(formattedLength), false);
	FormatSeconds(g_iBanInfo[client][iTimeLeft], formattedTimeLeft, sizeof(formattedTimeLeft), true);

	CReplyToCommand(client, "%s{purple}%N{default} is CT Banned %s by {purple}%s{default} for {orange}%s{default}. %s remaining", g_sChatPrefix, target, formattedLength, g_iBanInfo[target][sAdmin], g_iBanInfo[target][sReason], formattedTimeLeft);
	return Plugin_Handled;

}

public Action CMD_CTBan(int client, int args) {
	
	// Accepted inputs:
	// !ctban (Result: Menu with player, time, and reason)
	// !ctban <player> (Result: Menu with time and reason)
	// !ctban <player> <time> (Result: Menu with reason)
	// !ctban <player> <time> <reason>

	if (args > 3) {

		CReplyToCommand(client, "%sUsage: !ctban <player> <time> <reason>", g_sChatPrefix);
		return Plugin_Handled;

	}

	if (args != 3 && client == 0) {

		CReplyToCommand(client, "%sUsage: !ctban <player> <time> <reason>", g_sChatPrefix);
		return Plugin_Handled;

	}

	if (args == 0) {

		CTBanPlayerMenu(client);
		return Plugin_Handled;

	}

	char arg1[MAX_NAME_LENGTH];
	GetCmdArg(1, arg1, sizeof(arg1));

	int target = FindTarget(client, arg1, true, true);

	if (!IsValidClient(target)) {

		CReplyToCommand(client, "%sNot a valid target", g_sChatPrefix);
		return Plugin_Handled;

	}

	if (g_iBanInfo[target][iTimeLeft] > -1) {

		CReplyToCommand(client, "%s{purple}%N{default} is already CT Banned", g_sChatPrefix, target);
		return Plugin_Handled;

	}

	if (args == 1) {

		CTBanLengthMenu(client, target);
		return Plugin_Handled;

	}

	char arg2[MAX_NAME_LENGTH];
	GetCmdArg(2, arg2, sizeof(arg2));

	// Accept 1s, 2m, 3h, 4d, 5w, ect
	int time = 0, end = strlen(arg2)-1;
	if (IsCharNumeric(arg2[end])) {

		time = StringToInt(arg2) * 60;

	} else if (arg2[end] == 's') {

		arg2[end] = '\0';
		time = StringToInt(arg2);

	} else if(arg2[end] == 'm') {

		arg2[end] = '\0';
		time = StringToInt(arg2) * 60;

	} else if(arg2[end] == 'h') {

		arg2[end] = '\0';
		time = StringToInt(arg2) * 3600;

	} else if(arg2[end] == 'd') {

		arg2[end] = '\0';
		time = StringToInt(arg2) * 86400;

	} else if(arg2[end] == 'w') {

		arg2[end] = '\0';
		time = StringToInt(arg2) * 604800;

	}

	if (time < 0) {

		CReplyToCommand(client, "%sNot a valid time", g_sChatPrefix);
		return Plugin_Handled;

	}

	if (args == 2) {

		CTBanReasonMenu(client, target, time);
		return Plugin_Handled;

	}

	char arg3[MAX_NAME_LENGTH];
	GetCmdArg(3, arg3, sizeof(arg3));

	PerformCTBan(client, target, time, arg3);
	return Plugin_Handled;

}

public Action CMD_UnCTBan(int client, int args) {

	// Accepted inputs:
	// !unctban <player>

	if (args != 1) {

		CReplyToCommand(client, "%sUsage: !unctban <player>", g_sChatPrefix);
		return Plugin_Handled;

	}

	char arg1[MAX_NAME_LENGTH];
	GetCmdArg(1, arg1, sizeof(arg1));

	int target = FindTarget(client, arg1, true, false);

	if (!IsValidClient(target)) {

		CReplyToCommand(client, "%sNot a valid target", g_sChatPrefix);
		return Plugin_Handled;

	}

	if (g_iBanInfo[target][iTimeLeft] < 0) {

		CReplyToCommand(client, "%s{purple}%N{default} is not CT Banned", g_sChatPrefix, target);
		return Plugin_Handled;

	}

	char query[512], steamid[64];
	GetClientAuthId(target, AuthId_Engine, steamid, sizeof(steamid));

	Format(query, sizeof(query), "UPDATE `ctbans` SET `timeleft`= -1,`removed`= 'R' WHERE `perp_steamid` = '%s' AND `id` = %i;", steamid, g_iBanInfo[target][iID]);
	SQL_TQuery(g_hDB, SQL_ErrorCheckCallback, query, _, DBPrio_Low);

	g_iBanInfo[target][iCreated] = 0;
	g_iBanInfo[target][iLength] = -1;
	g_iBanInfo[target][iTimeLeft] = -1;
	Format(g_iBanInfo[target][sAdmin], 64, "");
	Format(g_iBanInfo[target][sReason], 120, "");

	CPrintToChatAll("%s{purple}%N{default} has removed {purple}%N's{default} CT Ban", g_sChatPrefix, client, target);

	return Plugin_Handled;

}

public Action CMD_OfflineCTBan(int client, int args) {

	// Accepted inputs:
	// !offlinectban <steamid>

	if (args > 3) {

		CReplyToCommand(client, "%sUsage: !offlinectban <steamid>", g_sChatPrefix);
		return Plugin_Handled;

	}

	char arg1[120];
	GetCmdArg(1, arg1, sizeof(arg1));

	PerformOfflineCTBan(client, arg1);

	return Plugin_Handled;

}

public Action CMD_RageCTBan(int client, int args) {

	// Accepted inputs:
	// !ragectban

	if (!IsValidClient(client)) {

		if (client == 0) {

			CReplyToCommand(client, "%sYou must be in game to use this command", g_sChatPrefix);			

		}

		return Plugin_Handled;

	}

	RageCTBanMenu(client);

	return Plugin_Handled;

}

// [ MENU HANDLERS ] //

public int CTBanPlayerMenuHandler(Menu menu, MenuAction action, int param1, int param2) {

	if (action == MenuAction_Select) {

		char useridString[4];
		menu.GetItem(param2, useridString, sizeof(useridString));

		int target = GetClientOfUserId(StringToInt(useridString));

		if (!IsValidClient(target)) {

			CPrintToChat(param1, "%sNot a valid target", g_sChatPrefix);
			return;

		}

		CTBanLengthMenu(param1, target);
		return;

	}
	
	if (action == MenuAction_End) {

		delete menu;

	}

}

public int CTBanLengthMenuHandler(Menu menu, MenuAction action, int param1, int param2) {

	if (action == MenuAction_Select) {

		char useridString[4], timeString[12];
		menu.GetItem(0, useridString, sizeof(useridString));
		menu.GetItem(param2, timeString, sizeof(timeString));

		int target = GetClientOfUserId(StringToInt(useridString));

		if (!IsValidClient(target)) {

			CPrintToChat(param1, "%sNot a valid target", g_sChatPrefix);
			return;

		}

		int time = StringToInt(timeString);

		if (time < 0) {
	
			CPrintToChat(param1, "%sNot a valid time", g_sChatPrefix);
			return;
	
		}

		CTBanReasonMenu(param1, target, time);
		return;

	}
	
	if (action == MenuAction_End) {

		delete menu;

	}

}

public int CTBanReasonMenuHandler(Menu menu, MenuAction action, int param1, int param2) {

	if (action == MenuAction_Select) {

		int style; // Not needed, just used so we can get the display text
		char useridString[4], timeString[12], reasonString[120];
		menu.GetItem(0, useridString, sizeof(useridString));
		menu.GetItem(1, timeString, sizeof(timeString));
		menu.GetItem(param2, reasonString, sizeof(reasonString), style, reasonString, sizeof(reasonString));

		int target = GetClientOfUserId(StringToInt(useridString));

		if (!IsValidClient(target)) {

			CPrintToChat(param1, "%sNot a valid target", g_sChatPrefix);
			return;

		}

		int time = StringToInt(timeString);

		if (time < 0) {
	
			CPrintToChat(param1, "%sNot a valid time", g_sChatPrefix);
			return;
	
		}

		PerformCTBan(param1, target, time, reasonString);
		return;

	}

	if (action == MenuAction_End) {

		delete menu;

	}

}

public int RageCTBanMenuHandler(Menu menu, MenuAction action, int param1, int param2) {

	if (action == MenuAction_Select) {

		char steamid[64];
		menu.GetItem(param2, steamid, sizeof(steamid));

		PerformOfflineCTBan(param1, steamid);

	}

	if (action == MenuAction_End) {

		delete menu;

	}

}

// [ TIMER CALLBACKS ] //

public Action CTBanTracker_Timer(Handle timer, int userid) {

	int client = GetClientOfUserId(userid);

	if (!IsValidClient(client)) {

		g_hCTBanTracker[client] = null;
		return Plugin_Stop;

	}
	
	if (g_hCTBanTracker[client] == null) {

		return Plugin_Stop;

	}

	if (!IsPlayerAlive(client)) {

		g_hCTBanTracker[client] = null;
		return Plugin_Stop;

	}

	if (g_iBanInfo[client][iTimeLeft] < 0) {

		g_hCTBanTracker[client] = null;
		return Plugin_Stop;

	}

	g_iBanInfo[client][iTimeLeft]--;

	if (g_iBanInfo[client][iTimeLeft] < 1) {

		char query[512], steamid[64];
		GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));

		Format(query, sizeof(query), "UPDATE `ctbans` SET `timeleft`= -1,`removed`= 'E' WHERE `perp_steamid` = '%s' AND `id` = %i;", steamid, g_iBanInfo[client][iID]);
		SQL_TQuery(g_hDB, SQL_ErrorCheckCallback, query, _, DBPrio_Low);

		g_iBanInfo[client][iCreated] = 0;
		g_iBanInfo[client][iLength] = -1;
		g_iBanInfo[client][iTimeLeft] = -1;
		Format(g_iBanInfo[client][sAdmin], 64, "");
		Format(g_iBanInfo[client][sReason], 120, "");

		CPrintToChatAll("%s{purple}%N's{default} CT Ban has expired", g_sChatPrefix, client);

		g_hCTBanTracker[client] = null;
		return Plugin_Stop;

	}

	return Plugin_Continue;

}

public Action RemoveRageInfo_Timer(Handle timer, int userid) {

	for (int i = 0; i < g_RageBans[0].Length; i++) {

		if (userid != g_RageBans[0].Get(i)) {

			continue;

		}

		g_RageBans[0].Erase(i);
		g_RageBans[1].Erase(i);
		g_RageBans[2].Erase(i);

		break;

	}

	return Plugin_Stop;

}

// [ PUBLIC FUNCTIONS ] //

public void CTBanPlayerMenu(int client) {

	Menu menu = new Menu(CTBanPlayerMenuHandler);
	menu.SetTitle("CT Ban\nChoose a Player:\n ");

	char useridString[4], userName[MAX_NAME_LENGTH];

	int count = 0;
	for (int i = 1; i <= MaxClients; i++) {
	
		if (!IsValidClient(i)) {
	
			continue;
	
		}

		if (client == i) {

			continue;

		}

		if (GetClientTeam(i) != GUARD_TEAM) {

			continue;

		}

		if (g_iBanInfo[i][iTimeLeft] > -1) {

			continue;
			
		}

		IntToString(GetClientUserId(i), useridString, sizeof(useridString));
		GetClientName(i, userName, sizeof(userName));

		menu.AddItem(useridString, userName);

		count++;

	}

	for (int i = 1; i <= MaxClients; i++) {
	
		if (!IsValidClient(i)) {
	
			continue;
	
		}

		if (client == i) {

			continue;

		}

		if (g_iBanInfo[i][iTimeLeft] > -1) {

			continue;
			
		}

		IntToString(GetClientUserId(i), useridString, sizeof(useridString));
		GetClientName(i, userName, sizeof(userName));

		menu.AddItem(useridString, userName);

		count++;

	}	

	if (count == 0) {

		CPrintToChat(client, "%sThere are no players to CT Ban", g_sChatPrefix);
		return;

	}

	menu.Pagination = 7;
	menu.Display(client, 0);

}

public void CTBanLengthMenu(int client, int target) {

	Menu menu = new Menu(CTBanLengthMenuHandler);
	menu.SetTitle("CT Ban\nChoose a Length:\n ");

	char useridString[4];
	IntToString(GetClientUserId(target), useridString, sizeof(useridString));

	menu.AddItem(useridString, "", ITEMDRAW_IGNORE);
	menu.AddItem("0", "Permanent");
	menu.AddItem("300", "5 Minutes");
	menu.AddItem("600", "10 Minutes");
	menu.AddItem("1800", "30 Minutes");
	menu.AddItem("3600", "1 Hour");
	menu.AddItem("7200", "2 Hours");
	menu.AddItem("14400", "4 Hours");

	menu.Pagination = 7;
	menu.Display(client, 0);

}

public void CTBanReasonMenu(int client, int target, int time) {

	Menu menu = new Menu(CTBanReasonMenuHandler);
	menu.SetTitle("CT Ban\nChoose a Reason:\n ");

	char useridString[4], timeString[12];
	IntToString(GetClientUserId(target), useridString, sizeof(useridString));
	IntToString(time, timeString, sizeof(timeString));

	menu.AddItem(useridString, "", ITEMDRAW_IGNORE);
	menu.AddItem(timeString, "", ITEMDRAW_IGNORE);
	
	char reason[120];
	for (int i = 0; i < g_aReasons.Length; i++) {

		g_aReasons.GetString(i, reason, sizeof(reason));
		menu.AddItem("", reason);

	}
	
	//menu.AddItem("", "Freekill Massacre");
	//menu.AddItem("", "Cheating / Exploiting");
	//menu.AddItem("", "Mic Spamming");
	//menu.AddItem("", "Poor Quality Mic");
	//menu.AddItem("", "Freekilling");
	//menu.AddItem("", "Gun Planting");
	//menu.AddItem("", "Breaking Rules");	

	menu.Pagination = 7;
	menu.Display(client, 0);

}

public void RageCTBanMenu(int client) {

	Menu menu = new Menu(RageCTBanMenuHandler);
	menu.SetTitle("Rage CT Ban\nChoose a Player:\n ");

	char steamid[64], name[MAX_NAME_LENGTH], nameString[MAX_NAME_LENGTH+64];

	int count = 0;
	for (int i = 0; i < g_RageBans[0].Length; i++) {

		g_RageBans[1].GetString(i, steamid, sizeof(steamid));
		g_RageBans[2].GetString(i, name, sizeof(name));

		Format(nameString, sizeof(nameString), "%s [%s]", name, steamid);
		menu.AddItem(steamid, nameString);

		count++;

	}

	if (count == 0) {

		CPrintToChat(client, "%sThere are no players to rage CT Ban", g_sChatPrefix);
		return;

	}

	menu.Pagination = 7;
	menu.Display(client, 0);	

}

public void PerformCTBan(int client, int target, int time, char[] reason) {

	if (!IsValidClient(client)) {

		return;

	}

	if (!IsValidClient(target)) {

		CPrintToChat(client, "%sNot a valid target", g_sChatPrefix);
		return;

	}

	if (g_iBanInfo[target][iTimeLeft] > -1) {

		CPrintToChat(client, "%s{purple}%N{default} is already CT Banned", g_sChatPrefix, target);
		return;

	}

	if (time < 0) {

		CPrintToChat(client, "%sNot a valid time", g_sChatPrefix);
		return;

	}

	if (strlen(reason) == 0) {

		Format(reason, 120, "Breaking Rules");

	}

	g_iBanInfo[target][iCount]++;
	g_iBanInfo[target][iCreated] = GetTime();
	g_iBanInfo[target][iLength] = time;
	g_iBanInfo[target][iTimeLeft] = time;
	
	GetClientName(client, g_iBanInfo[target][sAdmin], MAX_NAME_LENGTH);
	strcopy(g_iBanInfo[target][sReason], 120, reason);

	char targetSteamid[64], adminSteamid[64], adminName[MAX_NAME_LENGTH*2];

	GetClientAuthId(target, AuthId_Engine, targetSteamid, sizeof(targetSteamid));
	GetClientAuthId(client, AuthId_Engine, adminSteamid, sizeof(adminSteamid));

	GetClientName(client, adminName, sizeof(adminName));

	if (!SQL_EscapeString(g_hDB, adminName, adminName, sizeof(adminName))) {

		CPrintToChat(client, "%sFailed to add ban", g_sChatPrefix);
		LogError("(PerformCTBan) Failed to escape admin name: '%N'", client);
		return;

	}

	char query[512];
	Format(query, sizeof(query), "INSERT INTO `ctbans` VALUES (NULL, '%s', '%s', '%s', %i, %i, %i, 'N', '%s')", targetSteamid, adminSteamid, adminName, g_iBanInfo[target][iCreated], time, time, g_iBanInfo[target][sReason]);
	SQL_TQuery(g_hDB, SQL_ErrorCheckCallback, query, _, DBPrio_Low);

	if (GetClientTeam(target) == GUARD_TEAM) {

		ChangeClientTeam(target, PRISONER_TEAM);

	}

	char formattedLength[32];
	FormatSeconds(time, formattedLength, sizeof(formattedLength), false);
	CPrintToChatAll("%s{purple}%N{default} has CT Banned {purple}%N{default} %s for {orange}%s{default}", g_sChatPrefix, client, target, formattedLength, reason);

}

public void PerformOfflineCTBan(int client, char[] targetSteamid) {

	if (!IsValidClient(client)) {

		return;

	}

	if (StrContains(targetSteamid, "STEAM_", false) == -1) {

		CPrintToChat(client, "%sInvalid STEAMID (Ex: STEAM_1:)", g_sChatPrefix);
		return;

	}

	// Make sure all the steamids are using the same format
	ReplaceString(targetSteamid, 64, "STEAM_0:", "STEAM_1:", false);

	// Check if client is on server
	int target = -1;
	char tempSteam[64];
	for (int i = 1; i <= MaxClients; i++) {

		if (!IsValidClient(i)) {

			continue;

		}

		GetClientAuthId(i, AuthId_Engine, tempSteam, sizeof(tempSteam));

		if (StrEqual(targetSteamid, tempSteam)) {

			target = i;
			break;

		}

	}

	if (IsValidClient(target)) {

		CPrintToChat(client, "%s{purple}%N{default} is connected to the server, please use '!ctban %N'", g_sChatPrefix, target, target);
		return;

	}

	char adminSteamid[64], adminName[MAX_NAME_LENGTH*2];

	GetClientAuthId(client, AuthId_Engine, adminSteamid, sizeof(adminSteamid));
	GetClientName(client, adminName, sizeof(adminName));

	if (!SQL_EscapeString(g_hDB, targetSteamid, targetSteamid, 64)) {

		CPrintToChat(client,  "%sFailed to add ban", g_sChatPrefix);
		LogError("(PerformOfflineCTBan) Failed to escape steamid: '%s'", targetSteamid);
		return;

	}

	char query[512];
	Format(query, sizeof(query), "INSERT INTO `ctbans` VALUES (NULL, '%s', '%s', '%s', %i, 0, 0, 'N', 'Breaking Rules')", targetSteamid, adminSteamid, adminName, GetTime());
	SQL_TQuery(g_hDB, SQL_ErrorCheckCallback, query, _, DBPrio_Low);

	CPrintToChat(client, "%sYou have CT Banned {orange}%s{default} permanently", g_sChatPrefix, targetSteamid);
	return;

}

public void FormatSeconds(int seconds, char[] str, int len, bool timeleft) {

	if (seconds == 0) {

		if (timeleft) {

			Format(str, len, "{red}Indefinite{default} time");

		} else {

			Format(str, len, "{red}permanently{default}");

		}

	} else if (seconds < 60) {

		Format(str, len, "{blue}%i{default} second%s", seconds, seconds > 1 ? "s" : "");

	} else if (seconds < 3600) {

		Format(str, len, "{blue}%i{default} minute%s", RoundFloat(seconds / 60.0), RoundFloat(seconds / 60.0) == 1 ? "" : "s");

	} else if (seconds < 86400) {

		Format(str, len, "{blue}%i{default} hour%s", RoundFloat(seconds / 3600.0), seconds / RoundFloat(seconds / 3600.0) == 1 ? "" : "s");

	} else if (seconds >= 86400) {

		Format(str, len, "{blue}%i{default} day%s", RoundFloat(seconds / 86400.0), RoundFloat(seconds / 86400.0) == 1 ? "" : "s");

	}

	if (!timeleft && seconds > 0) {

		Format(str, len, "for %s", str);

	}

}

public void LoadReasons() {

	File file = OpenFile(g_sReasonsPath, "r");

	char line[120];
	while (!file.EndOfFile()) {

		file.ReadLine(line, sizeof(line));
		TrimString(line);

		if (strlen(line) == 0 || (line[0] == '/' && line[1] == '/')) {

			continue;

		}

		g_aReasons.PushString(line);

	}

	delete file;

}

public void PlayBlockSound(int client) {

	int clients[1];
	clients[0] = client;
	EmitSoundAny(clients, 1, g_sBlockSound);

}

public void ResetPlayer(int client) {

	g_bAuthorized[client] = false;
	g_bFirstSpawn[client] = false;

	g_iBanInfo[client][iID] = 0;
	g_iBanInfo[client][iCount] = 0;
	g_iBanInfo[client][iCreated] = 0;
	g_iBanInfo[client][iLength] = -1;
	g_iBanInfo[client][iTimeLeft] = -1;
	Format(g_iBanInfo[client][sAdmin], 64, "");
	Format(g_iBanInfo[client][sReason], 120, "");

}

public bool IsValidClient(int client) {

	if (client < 1 || client > MaxClients)
		return false;

	if (!IsClientInGame(client))
		return false;

	if (!IsClientConnected(client))
		return false;

	if (IsFakeClient(client))
		return false;

	if (IsClientSourceTV(client))
		return false;

	return true;

}