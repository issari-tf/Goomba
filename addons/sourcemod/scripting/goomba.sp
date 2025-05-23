#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

#pragma semicolon            1
#pragma newdecls             required

#define PL_NAME "Goomba Stomp Core"
#define PL_DESC "Goomba Stomp core plugin"
#define PL_VERSION "2.0.2"

#define STOMP_SOUND "goomba/stomp.wav"
#define REBOUND_SOUND "goomba/rebound.wav"

#define GOOMBA_IMMUNFLAG_NONE           0
#define GOOMBA_IMMUNFLAG_ATTACKER       (1 << 0)
#define GOOMBA_IMMUNFLAG_VICTIM         (1 << 1)

public Plugin myinfo = {
	name 				= PL_NAME,
	author 				= "Flyflo",
	description 		= PL_DESC,
	version 			= PL_VERSION,
	url 				= "http://www.geek-gaming.fr"
}

Handle g_hForwardOnStomp;
Handle g_hForwardOnStompPost;

Handle g_Cvar_JumpPower        = INVALID_HANDLE;
Handle g_Cvar_PluginEnabled    = INVALID_HANDLE;
Handle g_Cvar_ParticlesEnabled = INVALID_HANDLE;
Handle g_Cvar_SoundsEnabled    = INVALID_HANDLE;
Handle g_Cvar_ImmunityEnabled  = INVALID_HANDLE;
Handle g_Cvar_StompMinSpeed    = INVALID_HANDLE;

Handle g_Cvar_DamageLifeMultiplier = INVALID_HANDLE;
Handle g_Cvar_DamageAdd = INVALID_HANDLE;

// Snippet from psychonic (http://forums.alliedmods.net/showpost.php?p=1294224&postcount=2)
Handle sv_tags;

Handle g_Cookie_ClientPref;

int Goomba_Fakekill[MAXPLAYERS+1];

// Thx to Pawn 3-pg (https://forums.alliedmods.net/showthread.php?p=1140480#post1140480)
bool g_TeleportAtFrameEnd[MAXPLAYERS+1] = false;
float g_TeleportAtFrameEnd_Vel[MAXPLAYERS+1][3];

public APLRes AskPluginLoad2(Handle hMySelf, bool bLate, char[] strError, int iMaxErrors)
{
	RegPluginLibrary("goomba");

	CreateNative("GoombaStomp", GoombaStomp);
	CreateNative("CheckStompImmunity", CheckStompImmunity);
	CreateNative("PlayStompSound", PlayStompSound);
	CreateNative("PlayStompReboundSound", PlayStompReboundSound);
	CreateNative("EmitStompParticles", EmitStompParticles);

	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("goomba.phrases");

	g_Cvar_PluginEnabled    = CreateConVar("goomba_enabled", "1.0", "Plugin On/Off", 0, true, 0.0, true, 1.0);

	g_Cvar_SoundsEnabled    = CreateConVar("goomba_sounds", "1", "Enable or disable sounds of the plugin", 0, true, 0.0, true, 1.0);
	g_Cvar_ParticlesEnabled = CreateConVar("goomba_particles", "1", "Enable or disable particles of the plugin", 0, true, 0.0, true, 1.0);
	g_Cvar_ImmunityEnabled  = CreateConVar("goomba_immunity", "1", "Enable or disable the immunity system", 0, true, 0.0, true, 1.0);
	g_Cvar_JumpPower        = CreateConVar("goomba_rebound_power", "300.0", "Goomba jump power", 0, true, 0.0);
	g_Cvar_StompMinSpeed    = CreateConVar("goomba_minspeed", "360.0", "Minimum falling speed to kill", 0, true, 0.0, false, 0.0);
	// To remove the warning about this variable not being used
	GetConVarFloat(g_Cvar_StompMinSpeed);

	g_Cvar_DamageLifeMultiplier = CreateConVar("goomba_dmg_lifemultiplier", "1.0", "How much damage the victim will receive based on its actual life", 0, true, 0.0, false, 0.0);
	g_Cvar_DamageAdd            = CreateConVar("goomba_dmg_add", "50.0", "Add this amount of damage after goomba_dmg_lifemultiplier calculation", 0, true, 0.0, false, 0.0);

	AutoExecConfig(true, "goomba");

	CreateConVar("goomba_version", PL_VERSION, PL_NAME, FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_Cookie_ClientPref = RegClientCookie("goomba_client_pref", "", CookieAccess_Private);
	RegConsoleCmd("goomba_toggle", Cmd_GoombaToggle, "Toggle the goomba immunity client's pref.");
	RegConsoleCmd("goomba_status", Cmd_GoombaStatus, "Give the current goomba immunity setting.");
	RegConsoleCmd("goomba_on", Cmd_GoombaOn, "Enable stomp.");
	RegConsoleCmd("goomba_off", Cmd_GoombaOff, "Disable stomp.");

	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_spawn", Event_PlayerSpawn);

	char modName[32];
	GetGameFolderName(modName, sizeof(modName));

	HookEventEx("post_inventory_application", Event_LockerTouch);

	g_hForwardOnStomp = CreateGlobalForward("OnStomp", ET_Event, Param_Cell, Param_Cell, Param_FloatByRef, Param_FloatByRef, Param_FloatByRef);
	g_hForwardOnStompPost = CreateGlobalForward("OnStompPost", ET_Ignore, Param_Cell, Param_Cell, Param_Float, Param_Float, Param_Float);

	// sv_tags stuff
	sv_tags = FindConVar("sv_tags");
	MyAddServerTag("stomp");
	HookConVarChange(g_Cvar_PluginEnabled, OnPluginChangeState);

	// Support for plugin late loading
	for( int client=1; client<=MaxClients; client++ )
	{
		if(IsClientInGame(client))
		{
			OnClientPutInServer(client);
		}
	}
}

public void OnPluginEnd()
{
	MyRemoveServerTag("stomp");
}

public void OnMapStart()
{
	PrecacheSound(STOMP_SOUND, true);
	PrecacheSound(REBOUND_SOUND, true);

	char stompSoundServerPath[128];
	char reboundSoundServerPath[128];
	Format(stompSoundServerPath, sizeof(stompSoundServerPath), "sound/%s", STOMP_SOUND);
	Format(reboundSoundServerPath, sizeof(reboundSoundServerPath), "sound/%s", REBOUND_SOUND);

	AddFileToDownloadsTable(stompSoundServerPath);
	AddFileToDownloadsTable(reboundSoundServerPath);
}

public void OnPluginChangeState(Handle cvar, const char[] oldVal, const char[] newVal)
{
	if( GetConVarBool(g_Cvar_PluginEnabled) )
	{
		MyAddServerTag("stomp");
	} else {
		MyRemoveServerTag("stomp");
	}
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PreThinkPost, OnPreThinkPost);
}

public int CheckStompImmunity(Handle hPlugin, int numParams)
{
	if( numParams != 2 ) {
		return 3;
	
	}
	int client = GetNativeCell(1);
	int victim = GetNativeCell(2);
	int result = GOOMBA_IMMUNFLAG_NONE;
	if( GetConVarBool(g_Cvar_ImmunityEnabled) ) {
		char strCookieClient[16];
		GetImmunityCookie(client, g_Cookie_ClientPref, strCookieClient, sizeof(strCookieClient));

		char strCookieVictim[16];
		GetImmunityCookie(victim, g_Cookie_ClientPref, strCookieVictim, sizeof(strCookieVictim));

		if( StrEqual(strCookieClient, "on") || StrEqual(strCookieClient, "next_off") ) {
			result |= GOOMBA_IMMUNFLAG_ATTACKER;
		}
		if( StrEqual(strCookieVictim, "on") || StrEqual(strCookieVictim, "next_off") ) {
			result |= GOOMBA_IMMUNFLAG_VICTIM;
		}
	}

	return result;
}


public Action Event_PlayerDeath(Handle event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));

	if( Goomba_Fakekill[victim] == 1 )
	{
		SetEventBool(event, "goomba", true);
	}

	return Plugin_Continue;
}

public Action OnPreStomp(int attacker, int victim, float damageMultiplier, float damageBonus, float reboundPower)
{
	return Plugin_Continue;
}

public int GoombaStomp(Handle hPlugin, int numParams)
{
	// If the plugin is disabled stop here
	if( !GetConVarBool(g_Cvar_PluginEnabled) ) {
		return false;
	}
	if( numParams < 2 || numParams > 5 ) {
		return false;
	}

	// Retrieve the parameters
	int client = GetNativeCell(1);
	int victim = GetNativeCell(2);

	float damageMultiplier = GetConVarFloat(g_Cvar_DamageLifeMultiplier);
	float damageBonus = GetConVarFloat(g_Cvar_DamageAdd);
	float jumpPower = GetConVarFloat(g_Cvar_JumpPower);

	switch(numParams)
	{
		case 3:
			damageMultiplier = GetNativeCellRef(3);
		case 4:
			damageBonus = GetNativeCellRef(4);
		case 5:
			jumpPower = GetNativeCellRef(5);
	}

	float modifiedDamageMultiplier = damageMultiplier;
	float modifiedDamageBonus = damageBonus;
	float modifiedJumpPower = jumpPower;

	// Launch forward
	Action stompForwardResult;

	Call_StartForward(g_hForwardOnStomp);
	Call_PushCell(client);
	Call_PushCell(victim);
	Call_PushFloatRef(modifiedDamageMultiplier);
	Call_PushFloatRef(modifiedDamageBonus);
	Call_PushFloatRef(modifiedJumpPower);
	Call_Finish(stompForwardResult);

	if( stompForwardResult == Plugin_Changed ) {
		damageMultiplier = modifiedDamageMultiplier;
		damageBonus = modifiedDamageBonus;
		jumpPower = modifiedJumpPower;
	} else if(stompForwardResult == Plugin_Handled) {
		return false;
	}

	if(jumpPower > 0.0) {
		float vecAng[3], vecVel[3];
		GetClientEyeAngles(client, vecAng);
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", vecVel);
		vecAng[0] = DegToRad(vecAng[0]);
		vecAng[1] = DegToRad(vecAng[1]);
		vecVel[0] = jumpPower * Cosine(vecAng[0]) * Cosine(vecAng[1]);
		vecVel[1] = jumpPower * Cosine(vecAng[0]) * Sine(vecAng[1]);
		vecVel[2] = jumpPower + 100.0;

		g_TeleportAtFrameEnd[client] = true;
		g_TeleportAtFrameEnd_Vel[client] = vecVel;
	}

	int victim_health = GetClientHealth(victim);
	Goomba_Fakekill[victim] = 1;
	SDKHooks_TakeDamage(victim,
						client,
						client,
						victim_health * damageMultiplier + damageBonus,
						DMG_PREVENT_PHYSICS_FORCE | DMG_CRUSH | DMG_ALWAYSGIB);

	Goomba_Fakekill[victim] = 0;

	// Launch forward
	Call_StartForward(g_hForwardOnStompPost);
	Call_PushCell(client);
	Call_PushCell(victim);
	Call_PushFloat(damageMultiplier);
	Call_PushFloat(damageBonus);
	Call_PushFloat(jumpPower);
	Call_Finish();

	return true;
}

public int PlayStompReboundSound(Handle hPlugin, int numParams)
{
	if( numParams != 1 ) {
		return;
	
	}
	int client = GetNativeCell(1);
	if( IsClientInGame(client) ) {
		if( GetConVarBool(g_Cvar_SoundsEnabled) ) {
			EmitSoundToAll(REBOUND_SOUND, client);
		}
	}
}

public int PlayStompSound(Handle hPlugin, int numParams)
{
	if( numParams != 1 ) {
		return;
	
	}
	int client = GetNativeCell(1);
	if( IsClientInGame(client) ) {
		if( GetConVarBool(g_Cvar_SoundsEnabled) ) {
			EmitSoundToClient(client, STOMP_SOUND, client);
		}
	}
}

public int EmitStompParticles(Handle hPlugin, int numParams)
{
	if( numParams != 1 ) {
		return;
	
	}
	int client = GetNativeCell(1);
	if( GetConVarBool(g_Cvar_ParticlesEnabled) ) {
		int particle = AttachParticle(client, "mini_fireworks");
		if( particle != -1 ) {
			CreateTimer(5.0, Timer_DeleteParticle, EntIndexToEntRef(particle), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
}

public void OnPreThinkPost(int client)
{
	if( IsClientInGame(client) && IsPlayerAlive(client) ) {
		if( g_TeleportAtFrameEnd[client] ) {
			TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, g_TeleportAtFrameEnd_Vel[client]);
			if( GetConVarBool(g_Cvar_SoundsEnabled) ) {
				EmitSoundToAll(REBOUND_SOUND, client);
			}
		}
	}
	g_TeleportAtFrameEnd[client] = false;
}

stock void GetImmunityCookie(int client, Handle cookie, char[] strCookie, int maxlen)
{
	if( !AreClientCookiesCached(client) ) {
		strcopy(strCookie, maxlen, "off");
	} else {
		GetClientCookie(client, g_Cookie_ClientPref, strCookie, maxlen);
	}
}

public Action Event_PlayerSpawn(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));

	// Delay the update so class specific cfg are applied.
	CreateTimer(0.1, Timer_UpdateImmunity, client);
}

public Action Event_LockerTouch(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));

	// Delay the update so class specific cfg are applied (maybe not usefull for this event).
	CreateTimer(0.1, Timer_UpdateImmunity, client);
}

public Action Timer_UpdateImmunity(Handle timer, any client)
{
	char strCookie[16];
	GetImmunityCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));

	//-----------------------------------------------------
	// on       = Immunity enabled
	// off      = Immunity disabled
	// next_on  = Immunity enabled on respawn
	// next_off = Immunity disabled on respawn
	//-----------------------------------------------------

	if( StrEqual(strCookie, "") ) {
		SetClientCookie(client, g_Cookie_ClientPref, "off");
	} else if( StrEqual(strCookie, "next_off") ) {
		SetClientCookie(client, g_Cookie_ClientPref, "off");
	} else if( StrEqual(strCookie, "next_on") ) {
		SetClientCookie(client, g_Cookie_ClientPref, "on");
	}
}

public Action Cmd_GoombaToggle(int client, int args)
{
	if( GetConVarBool(g_Cvar_ImmunityEnabled) ) {
		char strCookie[16];
		GetImmunityCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));

		if( StrEqual(strCookie, "off") || StrEqual(strCookie, "next_off") ) {
			SetClientCookie(client, g_Cookie_ClientPref, "next_on");
			ReplyToCommand(client, "%t", "Immun On");
		} else {
			SetClientCookie(client, g_Cookie_ClientPref, "next_off");
			ReplyToCommand(client, "%t", "Immun Off");
		}
	} else {
		ReplyToCommand(client, "%t", "Immun Disabled");
	}
	return Plugin_Handled;
}

public Action Cmd_GoombaOn(int client, int args)
{
	if( GetConVarBool(g_Cvar_ImmunityEnabled) ) {
		char strCookie[16];
		GetImmunityCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));

		if( !StrEqual(strCookie, "off") ) {
			SetClientCookie(client, g_Cookie_ClientPref, "next_off");
			ReplyToCommand(client, "%t", "Immun Off");
		}
	} else {
		ReplyToCommand(client, "%t", "Immun Disabled");
	}
	return Plugin_Handled;
}

public Action Cmd_GoombaOff(int client, int args)
{
	if( GetConVarBool(g_Cvar_ImmunityEnabled) )
	{
		char strCookie[16];
		GetImmunityCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));
		if( !StrEqual(strCookie, "on") ) {
			SetClientCookie(client, g_Cookie_ClientPref, "next_on");
			ReplyToCommand(client, "%t", "Immun On");
		}
	} else {
		ReplyToCommand(client, "%t", "Immun Disabled");
	}
	return Plugin_Handled;
}

public Action Cmd_GoombaStatus(int client, int args)
{
	if( GetConVarBool(g_Cvar_ImmunityEnabled) ) {
		char strCookie[16];
		GetImmunityCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));

		if( StrEqual(strCookie, "on") ) {
			ReplyToCommand(client, "%t", "Status Off");
		}
		if( StrEqual(strCookie, "off") ) {
			ReplyToCommand(client, "%t", "Status On");
		}
		if( StrEqual(strCookie, "next_off") ) {
			ReplyToCommand(client, "%t", "Status Next On");
		}
		if( StrEqual(strCookie, "next_on") ) {
			ReplyToCommand(client, "%t", "Status Next Off");
		}
	} else {
		ReplyToCommand(client, "%t", "Immun Disabled");
	}

	return Plugin_Handled;
}

public Action Timer_DeleteParticle(Handle timer, any ref)
{
	int particle = EntRefToEntIndex(ref);
	DeleteParticle(particle);
}

stock int AttachParticle(int entity, char[] particleType)
{
	int particle = CreateEntityByName("info_particle_system");
	char tName[128];

	if( IsValidEdict(particle) ) {
		float pos[3] ;
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
		pos[2] += 74;
		TeleportEntity(particle, pos, NULL_VECTOR, NULL_VECTOR);

		Format(tName, sizeof(tName), "target%i", entity);

		DispatchKeyValue(entity, "targetname", tName);
		DispatchKeyValue(particle, "targetname", "tf2particle");
		DispatchKeyValue(particle, "parentname", tName);
		DispatchKeyValue(particle, "effect_name", particleType);
		DispatchSpawn(particle);

		SetVariantString(tName);
		SetVariantString("flag");
		ActivateEntity(particle);
		AcceptEntityInput(particle, "start");

		return particle;
	}
	return -1;
}

stock void DeleteParticle(any particle)
{
	if( particle > MaxClients && IsValidEntity(particle) ) {
		char classname[256];
		GetEdictClassname(particle, classname, sizeof(classname));

		if( StrEqual(classname, "info_particle_system", false) ) {
			AcceptEntityInput(particle, "Kill");
		}
	}
}

stock void MyAddServerTag(const char[] tag)
{
	char currtags[128];
	if( sv_tags == INVALID_HANDLE ) {
		return;
	}

	GetConVarString(sv_tags, currtags, sizeof(currtags));
	if( StrContains(currtags, tag) > -1 ) {
		// already have tag
		return;
	}

	char newtags[128];
	Format(newtags, sizeof(newtags), "%s%s%s", currtags, (currtags[0]!=0)?",":"", tag);
	int flags = GetConVarFlags(sv_tags);
	SetConVarFlags(sv_tags, flags & ~FCVAR_NOTIFY);
	SetConVarString(sv_tags, newtags);
	SetConVarFlags(sv_tags, flags);
}

stock void MyRemoveServerTag(const char[] tag)
{
	char newtags[128];
	if( sv_tags == INVALID_HANDLE ) {
		return;
	
	}
	GetConVarString(sv_tags, newtags, sizeof(newtags));
	if (StrContains(newtags, tag) == -1) {
		// tag isn't on here, just bug out
		return;
	}

	ReplaceString(newtags, sizeof(newtags), tag, "");
	ReplaceString(newtags, sizeof(newtags), ",,", "");
	int flags = GetConVarFlags(sv_tags);
	SetConVarFlags(sv_tags, flags & ~FCVAR_NOTIFY);
	SetConVarString(sv_tags, newtags);
	SetConVarFlags(sv_tags, flags);
}