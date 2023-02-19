#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <shop>

#define PLUGIN_VERSION	"3.0.0"
#pragma newdecls required

Handle g_hLookupAttachment = null;

KeyValues kv;

StringMap hTrieEntity[MAXPLAYERS+1];
StringMap hTrieItem[MAXPLAYERS+1];
Handle hTimer[MAXPLAYERS+1];
char sClLang[MAXPLAYERS+1][3];

ArrayList hCategories;

ConVar g_hPreview;
bool g_bPreview;
ConVar g_hRemoveOnDeath;
bool g_bRemoveOnDeath;

public Plugin myinfo =
{
    name        = "[Shop] Equipments",
    author      = "FrozDark (Shop Core team)",
    description = "Equipments component for shop",
    version     = PLUGIN_VERSION,
    url         = "www.hlmod.ru"
};

public void OnPluginStart()
{
	Handle hGameConf = LoadGameConfigFile("sdktools.games");
	if (hGameConf == null)
	{
		SetFailState("Not found gamedata - sdktools.games");
	}
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "LookupAttachment");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	if ((g_hLookupAttachment = EndPrepSDKCall()) == null)
	{
		SetFailState("Could not get \"LookupAttachment\" signature");
	}
	delete hGameConf;
	
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	
	hCategories = new ArrayList(ByteCountToCells(SHOP_MAX_STRING_LENGTH));
	
	RegAdminCmd("equipments_reload", Command_Reload, ADMFLAG_ROOT, "Reloads equipments configuration");
	
	g_hPreview = CreateConVar("sm_shop_equipments_preview", "1", "Enables preview for equipments");
	g_bPreview = g_hPreview.BoolValue;
	g_hPreview.AddChangeHook(OnConVarChange);
	
	g_hRemoveOnDeath = CreateConVar("sm_shop_equipments_remove_on_death", "1", "Removes a player's equipments on death");
	g_bRemoveOnDeath = g_hRemoveOnDeath.BoolValue;
	g_hRemoveOnDeath.AddChangeHook(OnConVarChange);
	
	AutoExecConfig(true, "shop_equipments", "shop");
	
	StartPlugin();
}

public void OnConVarChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == g_hPreview)
	{
		g_bPreview = view_as<bool>(StringToInt(newValue));
	}
	else if (convar == g_hRemoveOnDeath)
	{
		g_bRemoveOnDeath = view_as<bool>(StringToInt(newValue));
	}
}

void StartPlugin()
{
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (IsClientConnected(i))
		{
			OnClientConnected(i);
			if (IsClientInGame(i))
			{
				OnClientPutInServer(i);
			}
		}
	}
	
	if (Shop_IsStarted()) Shop_Started();
}

public void OnPluginEnd()
{
	Shop_UnregisterMe();
	for (int i = 1; i <= MaxClients; ++i)
	{
		OnClientDisconnect(i);
	}
}

public void Shop_Started()
{
	if (kv != null)
	{
		CloseHandle(kv);
	}
	
	kv = new KeyValues("Equipments");
	
	char _buffer[PLATFORM_MAX_PATH];
	Shop_GetCfgFile(_buffer, sizeof(_buffer), "equipments.txt");
	
	if (!kv.ImportFromFile(_buffer))
	{
		SetFailState("Couldn't parse file %s", _buffer);
	}
	
	hCategories.Clear();
	
	char lang[3];
	char phrase[SHOP_MAX_STRING_LENGTH];
	GetLanguageInfo(GetServerLanguage(), lang, sizeof(lang));
	
	if (kv.GotoFirstSubKey())
	{
		char item[SHOP_MAX_STRING_LENGTH];
		char model[PLATFORM_MAX_PATH];
		do 
		{
			kv.GetSectionName(_buffer, sizeof(_buffer));
			if (!_buffer[0]) continue;
			
			if (hCategories.FindString(_buffer) == -1)
			{
				hCategories.PushString(_buffer);
			}
			
			kv.GetString(lang, phrase, sizeof(phrase), "LangError");
			CategoryId category_id = Shop_RegisterCategory(_buffer, phrase, "", OnCategoryDisplay);
			
			int symbol;
			kv.GetSectionSymbol(symbol);
			if (kv.GotoFirstSubKey())
			{
				do 
				{
					if (kv.GetSectionName(item, sizeof(item)))
					{
						kv.GetString("model", model, sizeof(model));
						int pos = FindCharInString(model, '.', true);
						if (pos != -1 && StrEqual(model[pos+1], "mdl", false) && Shop_StartItem(category_id, item))
						{
							PrecacheModel(model, true);
							
							kv.GetString("name", _buffer, sizeof(_buffer), item);
							Shop_SetInfo(_buffer, "", kv.GetNum("price", 5000), kv.GetNum("sell_price", 2500), Item_Togglable, kv.GetNum("duration", 86400), kv.GetNum("gold_price", 5000), kv.GetNum("gold_sell_price", 2500));
							Shop_SetCallbacks(_, OnEquipItem);
							
							kv.JumpToKey("Attributes", true);
							Shop_KvCopySubKeysCustomInfo(view_as<KeyValues>(kv));
							kv.GoBack();
							
							Shop_EndItem();
						}
					}
				}
				while (kv.GotoNextKey());
				
				kv.Rewind();
				kv.JumpToKeySymbol(symbol);
			}
		}
		while (kv.GotoNextKey());
	}
	kv.Rewind();
}

public bool OnCategoryDisplay(int client, CategoryId category_id, const char[] category, const char[] name, char[] buffer, int maxlen, ShopMenu menu)
{
	bool result = false;
	if (kv.JumpToKey(category))
	{
		kv.GetString(sClLang[client], buffer, maxlen, name);
		result = true;
	}
	kv.Rewind();
	return result;
}

public Action Command_Reload(int client, int args)
{
	OnPluginEnd();
	StartPlugin();
	OnMapStart();
	ReplyToCommand(client, "Equipments configuration successfuly reloaded!");
	return Plugin_Handled;
}

public void OnMapStart()
{
	if (kv == null)
	{
		return;
	}
	
	char buffer[PLATFORM_MAX_PATH];
	Shop_GetCfgFile(buffer, sizeof(buffer), "equipments_downloads.txt");
	File_ReadDownloadList(buffer);
	if (kv.GotoFirstSubKey())
	{
		do
		{
			kv.SavePosition();
			if (kv.GotoFirstSubKey())
			{
				do 
				{
					kv.GetString("model", buffer, sizeof(buffer));
					int pos = FindCharInString(buffer, '.', true);
					if (pos != -1 && StrEqual(buffer[pos+1], "mdl", false))
					{
						PrecacheModel(buffer, true);
					}
				} while (kv.GotoNextKey());
				
				kv.GoBack();
			}
		} while (kv.GotoNextKey());
	}
	
	kv.Rewind();
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		hTimer[i] = null;
	}
}

public void OnClientConnected(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}
	
	hTrieEntity[client] = new StringMap();
	hTrieItem[client] = new StringMap();
}

public void OnClientPutInServer(int client)
{
	//SDKHook(client, SDKHook_OnTakeDamagePost, OnTakeDamagePost);
	GetLanguageInfo(GetClientLanguage(client), sClLang[client], sizeof(sClLang[]));
}

public void OnClientDisconnect(int client)
{
	ProcessDequip(client);
}

public void OnClientDisconnect_Post(int client)
{
	if (hTrieEntity[client] != null)
	{
		delete hTrieEntity[client];
		hTrieEntity[client] = null;
	}
	if (hTrieItem[client] != null)
	{
		delete hTrieItem[client];
		hTrieItem[client] = null;
	}
	if (hTimer[client] != null)
	{
		KillTimer(hTimer[client]);
		hTimer[client] = null;
	}
}

/*public OnTakeDamagePost(victim, attacker, inflictor, Float:damage, damagetype, weapon, const Float:damageForce[3], const Float:damagePosition[3])
{
	if (!IsFakeClient(victim) && GetClientHealth(victim)-damage < 1)
	{
		if (!g_bRemoveOnDeath)
		{
			decl String:category[64], String:sModel[PLATFORM_MAX_PATH];
			for (new i = 0; i < hCategories.Length; i++)
			{
				hCategories.GetString(i, category, sizeof(category));
				
				new ref = -1;
				if (!hTrieEntity[victim].GetValue(category, ref))
				{
					continue;
				}
				
				new entity = EntRefToEntIndex(ref);
				if (entity != INVALID_ENT_REFERENCE && IsValidEdict(entity))
				{
					GetEntPropString(entity, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
					
					decl Float:fPos[3];
					GetClientEyePosition(victim, fPos);
					fPos[2] += 100.0;
					
					new ent = CreateEntityByName("prop_physics");
					SetEntProp(ent, Prop_Data, "m_CollisionGroup", 2);
					SetEntityModel(ent, sModel);
					DispatchSpawn(ent);
					
					TeleportEntity(ent, fPos, NULL_VECTOR, damageForce);
				}
			}
		}
		ProcessDequip(victim);
	}
}*/

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (hTrieEntity[client] == null)
	{
		return;
	}
	if (!g_bRemoveOnDeath)
	{
		char category[SHOP_MAX_STRING_LENGTH]; char sModel[PLATFORM_MAX_PATH];
		for (int i = 0; i < hCategories.Length; i++)
		{
			hCategories.GetString(i, category, sizeof(category));
			
			int ref = -1;
			if (!hTrieEntity[client].GetValue(category, ref))
			{
				continue;
			}
			
			int entity = EntRefToEntIndex(ref);
			if (entity != INVALID_ENT_REFERENCE && IsValidEdict(entity))
			{
				GetEntPropString(entity, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
				
				float fPos[3];
				GetClientEyePosition(client, fPos);
				
				int ent = CreateEntityByName("prop_physics");
				if (ent != -1)
				{
					SetEntProp(ent, Prop_Data, "m_CollisionGroup", 2);
					SetEntityModel(ent, sModel);
					
					if (!DispatchSpawn(ent))
					{
						PrintToChatAll("Could not spawn %s", sModel);
					}
				}
				
				TeleportEntity(ent, fPos, NULL_VECTOR, NULL_VECTOR);
			}
		}
	}
	ProcessDequip(client);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	CreateTimer(0.1, SpawnTimer, userid, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public Action SpawnTimer(Handle timer, any userid)
{
	static int dum[MAXPLAYERS+1];
	
	int client = GetClientOfUserId(userid);
	if (!client || hTrieEntity[client] == null || IsFakeClient(client))
	{
		dum[client] = 0;
		return Plugin_Stop;
	}
	
	int size = hCategories.Length;
	if (!size || dum[client] >= size)
	{
		dum[client] = 0;
		return Plugin_Stop;
	}
	
	char category[SHOP_MAX_STRING_LENGTH];
	hCategories.GetString(dum[client]++, category, sizeof(category));
	Equip(client, category);
	
	return Plugin_Continue;
}

public ShopAction OnEquipItem(int client, CategoryId category_id, const char[] category, ItemId item_id, const char[] item, bool isOn, bool elapsed)
{
	if (isOn || elapsed)
	{
		Dequip(client, category);
		hTrieItem[client].Remove(category);
		return Shop_UseOff;
	}
	
	Shop_ToggleClientCategoryOff(client, category_id);
	SetTrieString(hTrieItem[client], category, item);
	if (!Equip(client, category, true))
	{
		return Shop_UseOff;
	}
	
	return Shop_UseOn;
}

public Action SetBackMode(Handle timer, any client)
{
	Client_SetThirdPersonMode(client, false);
	hTimer[client] = null;

	return Plugin_Handled;
}

bool Equip(int client, const char[] category, bool from_select = false)
{
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return true;
	}
	
	Dequip(client, category);
	
	char item[SHOP_MAX_STRING_LENGTH];
	if (!GetTrieString(hTrieItem[client], category, item, sizeof(item)))
	{
		return false;
	}

	float fAng[3];
	float fPos[3];

	char entModel[PLATFORM_MAX_PATH];
	char attachment[32]; char alt_attachment[32];
	entModel[0] = '\0';
	
	kv.Rewind();
	if (kv.JumpToKey(category) && kv.JumpToKey(item))
	{
		kv.GetString("model", entModel, sizeof(entModel));
		if (!entModel[0])
		{
			kv.Rewind();
			return false;
		}
		
		char buffer[PLATFORM_MAX_PATH];
		GetClientModel(client, buffer, sizeof(buffer));
		ReplaceString(buffer, sizeof(buffer), "/", "\\");
		if (kv.JumpToKey("classes"))
		{
			if (kv.JumpToKey(buffer, false))
			{
				kv.GetString("attachment", attachment, sizeof(attachment), "forward");
				kv.GetString("alt_attachment", alt_attachment, sizeof(alt_attachment), "");
				KvGetVector(kv, "position", fPos);
				KvGetVector(kv, "angles", fAng);
			}
			else
			{
				kv.GoBack();
				kv.GetString("attachment", attachment, sizeof(attachment), "forward");
				kv.GetString("alt_attachment", alt_attachment, sizeof(alt_attachment), "");
				KvGetVector(kv, "position", fPos);
				KvGetVector(kv, "angles", fAng);
			}
		}
		else
		{
			kv.GetString("attachment", attachment, sizeof(attachment), "forward");
			kv.GetString("alt_attachment", alt_attachment, sizeof(alt_attachment), "");
			KvGetVector(kv, "position", fPos);
			KvGetVector(kv, "angles", fAng);
		}
	
		if (attachment[0])
		{
			if (!LookupAttachment(client, attachment))
			{
				if (alt_attachment[0])
				{
					if (!LookupAttachment(client, alt_attachment))
					{
						PrintToChat(client, "\x04[Shop] \x01Your current model is not supported. Reason: \x04Neither attachment \"\x03%s\x04\" nor \"\x03%s\x04\" is exists on your model (%s)", attachment, alt_attachment, buffer);
						kv.Rewind();
						return false;
					}
					strcopy(attachment, sizeof(attachment), alt_attachment);
				}
				else
				{
					PrintToChat(client, "\x04[Shop] \x01Your current model is not supported. Reason: \x04Attachment \"\x03%s\x04\" is not exists on your model (%s)", attachment, buffer);
					return false;
				}
			}
		}
	}
	kv.Rewind();

	float or[3];
	float ang[3];
	float fForward[3];
	float fRight[3];
	float fUp[3];
	
	GetClientAbsOrigin(client, or);
	GetClientAbsAngles(client, ang);

	ang[0] += fAng[0];
	ang[1] += fAng[1];
	ang[2] += fAng[2];
	
	GetAngleVectors(ang, fForward, fRight, fUp);

	or[0] += fRight[0]*fPos[0] + fForward[0]*fPos[1] + fUp[0]*fPos[2];
	or[1] += fRight[1]*fPos[0] + fForward[1]*fPos[1] + fUp[1]*fPos[2];
	or[2] += fRight[2]*fPos[0] + fForward[2]*fPos[1] + fUp[2]*fPos[2];

	int ent = CreateEntityByName("prop_dynamic_override");
	DispatchKeyValue(ent, "model", entModel);
	DispatchKeyValue(ent, "spawnflags", "256");
	DispatchKeyValue(ent, "solid", "0");
	
	// We give the name for our entities here
	char tName[24];
	Format(tName, sizeof(tName), "shop_equip_%d", ent);
	DispatchKeyValue(ent, "targetname", tName);
	
	DispatchSpawn(ent);	
	AcceptEntityInput(ent, "TurnOn", ent, ent, 0);
	
	SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", client);
	
	SetTrieValue(hTrieEntity[client], category, EntIndexToEntRef(ent), true);
	
	SDKHook(ent, SDKHook_SetTransmit, ShouldHide);
	
	TeleportEntity(ent, or, ang, NULL_VECTOR); 
	
	SetVariantString("!activator");
	AcceptEntityInput(ent, "SetParent", client, ent, 0);
	
	if (attachment[0])
	{
		SetVariantString(attachment);
		AcceptEntityInput(ent, "SetParentAttachmentMaintainOffset", ent, ent, 0);
	}
	
	if (from_select && g_bPreview)
	{
		if (hTimer[client] != null)
		{
			KillTimer(hTimer[client]);
			hTimer[client] = null;
		}
		
		hTimer[client] = CreateTimer(1.0, SetBackMode, client, TIMER_FLAG_NO_MAPCHANGE);
		
		Client_SetThirdPersonMode(client, true);
	}
	
	return true;
}

void ProcessDequip(int client)
{
	if (hTrieEntity[client] == null)
	{
		return;
	}
	
	char category[SHOP_MAX_STRING_LENGTH];
	for (int i = 0; i < hCategories.Length; i++)
	{
		hCategories.GetString(i, category, sizeof(category));
		Dequip(client, category);
	}
}

void Dequip(int client, const char[] category)
{  
	int ref = -1;
	if (!hTrieEntity[client].GetValue(category, ref))
	{
		return;
	}
	int entity = EntRefToEntIndex(ref);
	if (entity != INVALID_ENT_REFERENCE && IsValidEdict(entity))
	{
		AcceptEntityInput(entity, "Kill");
	}
	
	hTrieEntity[client].Remove(category);
}

public Action ShouldHide(int ent, int client)
{
	if (Client_IsInThirdPersonMode(client) && IsPlayerAlive(client))
	{
		return Plugin_Continue;
	}

	int owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
	if (owner == client)
	{
		return Plugin_Handled;
	}

	if (GetEntProp(client, Prop_Send, "m_iObserverMode") == 4)
	{
		if (owner == GetEntPropEnt(client, Prop_Send, "m_hObserverTarget"))
		{
			return Plugin_Handled;
		}
	}
	
	return Plugin_Continue;
}

stock bool LookupAttachment(int client, const char[] point)
{
    if (g_hLookupAttachment==null) return false;
    if (client < 1 || !IsClientInGame(client)) return false;
	
    return SDKCall(g_hLookupAttachment, client, point);
}

char _smlib_empty_twodimstring_array[][] = { { '\0' } };
stock void File_AddToDownloadsTable(const char[] path, bool recursive=true, const char[][] ignoreExts=_smlib_empty_twodimstring_array, int size=0)
{
	if (path[0] == '\0') {
		return;
	}

	if (FileExists(path)) {
		
		char fileExtension[4];
		File_GetExtension(path, fileExtension, sizeof(fileExtension));
		
		if (StrEqual(fileExtension, "bz2", false) || StrEqual(fileExtension, "ztmp", false)) {
			return;
		}
		
		if (Array_FindString(ignoreExts, size, fileExtension) != -1) {
			return;
		}

		AddFileToDownloadsTable(path);
		
		if (StrEqual(fileExtension, "mdl", false))
		{
			PrecacheModel(path, true);
		}
	}
	
	else if (recursive && DirExists(path)) {

		char dirEntry[PLATFORM_MAX_PATH];
		DirectoryListing __dir = OpenDirectory(path);

		while (__dir.GetNext(dirEntry, sizeof(dirEntry))) {

			if (StrEqual(dirEntry, ".") || StrEqual(dirEntry, "..")) {
				continue;
			}
			
			Format(dirEntry, sizeof(dirEntry), "%s/%s", path, dirEntry);
			File_AddToDownloadsTable(dirEntry, recursive, ignoreExts, size);
		}
		
		delete __dir;
	}
	else if (FindCharInString(path, '*', true)) {
		
		char fileExtension[4];
		File_GetExtension(path, fileExtension, sizeof(fileExtension));

		if (StrEqual(fileExtension, "*")) {
			char dirName[PLATFORM_MAX_PATH];
			char fileName[PLATFORM_MAX_PATH];
			char dirEntry[PLATFORM_MAX_PATH];

			File_GetDirName(path, dirName, sizeof(dirName));
			File_GetFileName(path, fileName, sizeof(fileName));
			StrCat(fileName, sizeof(fileName), ".");

			DirectoryListing __dir = OpenDirectory(dirName);
			while (__dir.GetNext(dirEntry, sizeof(dirEntry))) {

				if (StrEqual(dirEntry, ".") || StrEqual(dirEntry, "..")) {
					continue;
				}

				if (strncmp(dirEntry, fileName, strlen(fileName)) == 0) {
					Format(dirEntry, sizeof(dirEntry), "%s/%s", dirName, dirEntry);
					File_AddToDownloadsTable(dirEntry, recursive, ignoreExts, size);
				}
			}

			delete __dir;
		}
	}

	return;
}

stock bool File_ReadDownloadList(const char[] path)
{
	File file = OpenFile(path, "r");
	
	if (file == null) {
		return false;
	}

	char buffer[PLATFORM_MAX_PATH];
	while (!file.EndOfFile()) {
		file.ReadLine(buffer, sizeof(buffer));
		
		int pos;
		pos = StrContains(buffer, "//");
		if (pos != -1) {
			buffer[pos] = '\0';
		}
		
		pos = StrContains(buffer, "#");
		if (pos != -1) {
			buffer[pos] = '\0';
		}

		pos = StrContains(buffer, ";");
		if (pos != -1) {
			buffer[pos] = '\0';
		}
		
		TrimString(buffer);
		
		if (buffer[0] == '\0') {
			continue;
		}

		File_AddToDownloadsTable(buffer);
	}

	delete file;
	
	return true;
}

stock void File_GetExtension(const char[] path, char[] buffer, int size)
{
	int extpos = FindCharInString(path, '.', true);
	
	if (extpos == -1)
	{
		buffer[0] = '\0';
		return;
	}

	strcopy(buffer, size, path[++extpos]);
}

stock int Math_GetRandomInt(int min, int max)
{
	int random = GetURandomInt();
	
	if (random == 0)
		random++;

	return RoundToCeil(float(random) / (float(2147483647) / float(max - min + 1))) + min - 1;
}

stock int Array_FindString(const char[][] array, int size, const char[] str, bool caseSensitive=true, int start=0)
{
	if (start < 0) {
		start = 0;
	}

	for (int i = start; i < size; i++) {

		if (StrEqual(array[i], str, caseSensitive)) {
			return i;
		}
	}
	
	return -1;
}

stock void File_GetFileName(const char[] path, char[] buffer, int size)
{	
	if (path[0] == '\0') {
		buffer[0] = '\0';
		return;
	}
	
	File_GetBaseName(path, buffer, size);
	
	int pos_ext = FindCharInString(buffer, '.', true);

	if (pos_ext != -1) {
		buffer[pos_ext] = '\0';
	}
}

stock void File_GetDirName(const char[] path, char[] buffer, int size)
{	
	if (path[0] == '\0') {
		buffer[0] = '\0';
		return;
	}
	
	int pos_start = FindCharInString(path, '/', true);
	
	if (pos_start == -1) {
		pos_start = FindCharInString(path, '\\', true);
		
		if (pos_start == -1) {
			buffer[0] = '\0';
			return;
		}
	}
	
	strcopy(buffer, size, path);
	buffer[pos_start] = '\0';
}

stock void File_GetBaseName(const char[] path, char[] buffer, int size)
{	
	if (path[0] == '\0') {
		buffer[0] = '\0';
		return;
	}
	
	int pos_start = FindCharInString(path, '/', true);
	
	if (pos_start == -1) {
		pos_start = FindCharInString(path, '\\', true);
	}
	
	pos_start++;
	
	strcopy(buffer, size, path[pos_start]);
}



// Spectator Movement modes
enum Obs_Mode
{
	OBS_MODE_NONE = 0,	// not in spectator mode
	OBS_MODE_DEATHCAM,	// special mode for death cam animation
	OBS_MODE_FREEZECAM,	// zooms to a target, and freeze-frames on them
	OBS_MODE_FIXED,		// view from a fixed camera position
	OBS_MODE_IN_EYE,	// follow a player in first person view
	OBS_MODE_CHASE,		// follow a player in third person view
	OBS_MODE_ROAMING,	// free roaming

	NUM_OBSERVER_MODES
};

enum Obs_Allow
{
	OBS_ALLOW_ALL = 0,	// allow all modes, all targets
	OBS_ALLOW_TEAM,		// allow only own team & first person, no PIP
	OBS_ALLOW_NONE,		// don't allow any spectating after death (fixed & fade to black)

	OBS_ALLOW_NUM_MODES,
};

stock Obs_Mode Client_GetObserverMode(int client)
{
	return view_as<Obs_Mode>(
		GetEntProp(client, Prop_Send, "m_iObserverMode")
	);
}

stock bool Client_SetObserverMode(int client, Obs_Mode mode, bool updateMoveType=true)
{
	if (mode < OBS_MODE_NONE || mode >= NUM_OBSERVER_MODES) {
		return false;
	}
	
	// check mp_forcecamera settings for dead players
	if (mode > OBS_MODE_FIXED && GetClientTeam(client) > 1)
	{
		ConVar mp_forcecamera = FindConVar("mp_forcecamera");

		if (mp_forcecamera != null) {
			switch (view_as<Obs_Allow>(GetConVarInt(mp_forcecamera)))
			{
				case OBS_ALLOW_TEAM: {
					mode = OBS_MODE_IN_EYE;
				}
				case OBS_ALLOW_NONE: {
					mode = OBS_MODE_FIXED; // don't allow anything
				}
			}
		}
	}

	Obs_Mode observerMode = Client_GetObserverMode(client);
	if (observerMode > OBS_MODE_DEATHCAM) {
		// remember mode if we were really spectating before
		Client_SetObserverLastMode(client, observerMode);
	}

	SetEntProp(client, Prop_Send, "m_iObserverMode", mode);

	switch (mode) {
		case OBS_MODE_NONE, OBS_MODE_FIXED, OBS_MODE_DEATHCAM: {
			Client_SetFOV(client, 0);	// Reset FOV
			
			if (updateMoveType) {
				SetEntityMoveType(client, MOVETYPE_NONE);
			}
		}
		case OBS_MODE_CHASE, OBS_MODE_IN_EYE: {
			// udpate FOV and viewmodels
			Client_SetViewOffset(client, NULL_VECTOR);
			
			if (updateMoveType) {
				SetEntityMoveType(client, MOVETYPE_OBSERVER);
			}
		}
		case OBS_MODE_ROAMING: {
			Client_SetFOV(client, 0);	// Reset FOV
			Client_SetViewOffset(client, NULL_VECTOR);
			
			if (updateMoveType) {
				SetEntityMoveType(client, MOVETYPE_OBSERVER);
			}
		}
	}

	return true;
}

stock Obs_Mode Client_GetObserverLastMode(int client)
{
	return view_as<Obs_Mode>(
		GetEntProp(client, Prop_Data, "m_iObserverLastMode")
	);
}

stock void Client_SetObserverLastMode(int client, Obs_Mode mode)
{
	SetEntProp(client, Prop_Data, "m_iObserverLastMode", mode);
}

stock void Client_GetViewOffset(int client, float vec[3])
{
	GetEntPropVector(client, Prop_Data, "m_vecViewOffset", vec);
}

stock void Client_SetViewOffset(int client, float vec[3])
{
	SetEntPropVector(client, Prop_Data, "m_vecViewOffset", vec);
}

stock int Client_GetObserverTarget(int client)
{
	return GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
}

stock void Client_SetObserverTarget(int client, int entity, bool resetFOV=true)
{
	SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", entity);
	
	if (resetFOV) {
		Client_SetFOV(client, 0);
	}
}

stock int Client_GetFOV(int client)
{
	return GetEntProp(client, Prop_Send, "m_iFOV");
}

stock void Client_SetFOV(int client, int value)
{
	SetEntProp(client, Prop_Send, "m_iFOV", value);
}

stock bool Client_DrawViewModel(int client)
{
	return view_as<bool>(
		GetEntProp(client, Prop_Send, "m_bDrawViewmodel")
	);
}

stock void Client_SetDrawViewModel(int client, bool drawViewModel)
{
	SetEntProp(client, Prop_Send, "m_bDrawViewmodel", drawViewModel);
}

stock void Client_SetThirdPersonMode(int client, bool enable=true)
{
	if (enable) {
		Client_SetObserverTarget(client, 0);
		Client_SetObserverMode(client, OBS_MODE_DEATHCAM, false);
		Client_SetDrawViewModel(client, false);
		Client_SetFOV(client, 120);
	}
	else {
		Client_SetObserverTarget(client, -1);
		Client_SetObserverMode(client, OBS_MODE_NONE, false);
		Client_SetDrawViewModel(client, true);
		Client_SetFOV(client, 90);
	}
}

stock int Client_IsInThirdPersonMode(int client)
{
	return GetEntProp(client, Prop_Data, "m_iObserverMode");
}