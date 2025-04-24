#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <tf2_stocks>
#include <morecolors>
#include <goomba>

enum struct GoombaCvars {
	ConVar StompMinSpeed;
	ConVar UberImun;
	ConVar CloakImun;
	ConVar StunImun;
	ConVar StompUndisguise;
	ConVar CloakedImun;
	ConVar BonkedImun;
	ConVar FriendlyFire;
}

int Goomba_SingleStomp[MAXPLAYERS+1] = 0;

#define PL_NAME     "Goomba Stomp TF2"
#define PL_DESC     "Goomba Stomp TF2 plugin"
#define PL_VERSION  "1.1.0"

enum struct GoombaGlobals {
	GoombaCvars m_hCvars;
}

GoombaGlobals   g_goomba;

public Plugin myinfo = {
	name                = PL_NAME,
	author              = "Flyflo",
	description         = PL_DESC,
	version             = PL_VERSION,
	url                 = "http://www.geek-gaming.fr"
}

public void OnPluginStart() {
	char modName[32];
	GetGameFolderName(modName, sizeof(modName));

	if( !StrEqual(modName, "tf", false) ) {
		SetFailState("This plugin only works with Team Fortress 2");
	
	}
	LoadTranslations("goomba.phrases");

	g_goomba.m_hCvars.UberImun          = CreateConVar("goomba_uber_immun", "1.0", "Prevent ubercharged players from being stomped", 0, true, 0.0, true, 1.0);
	g_goomba.m_hCvars.CloakImun         = CreateConVar("goomba_cloak_immun", "1.0", "Prevent cloaked spies from stomping", 0, true, 0.0, true, 1.0);
	g_goomba.m_hCvars.StunImun          = CreateConVar("goomba_stun_immun", "1.0", "Prevent stunned players from being stomped", 0, true, 0.0, true, 1.0);
	g_goomba.m_hCvars.StompUndisguise   = CreateConVar("goomba_undisguise", "1.0", "Undisguise spies after stomping", 0, true, 0.0, true, 1.0);
	g_goomba.m_hCvars.CloakedImun       = CreateConVar("goomba_cloaked_immun", "0.0", "Prevent cloaked spies from being stomped", 0, true, 0.0, true, 1.0);
	g_goomba.m_hCvars.BonkedImun        = CreateConVar("goomba_bonked_immun", "1.0", "Prevent bonked scout from being stomped", 0, true, 0.0, true, 1.0);
	g_goomba.m_hCvars.FriendlyFire      = CreateConVar("goomba_friendlyfire", "0.0", "Enable friendly fire, \"tf_avoidteammates\" and \"mp_friendlyfire\" must be set to 1", 0, true, 0.0, true, 1.0);

	AutoExecConfig(true, "goomba.tf");
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	
	// Support for plugin late loading
	for( int client=1; client<=MaxClients; client++ ) {
		if( IsClientInGame(client) ) {
			OnClientPutInServer(client);
		}
	}
}

public void OnConfigsExecuted()
{
	g_goomba.m_hCvars.StompMinSpeed     = FindConVar("goomba_minspeed");
	if( g_goomba.m_hCvars.StompMinSpeed == INVALID_HANDLE ) 
	{
		SetFailState("Unable to find the goomba_minspeed cvar, make sure goomba core plugin is correctly loaded.");
	}
}

public Action OnStomp(int attacker, int victim, float& damageMultiplier, float& damageBonus, float& reboundPower) 
{
	if( TF2_IsPlayerInCondition(victim, TFCond_Ubercharged) && !GetConVarBool(g_goomba.m_hCvars.UberImun) ) {
		TF2_RemoveCondition(victim, TFCond_Ubercharged);
	
	}
	return Plugin_Continue;
}

public void OnClientPutInServer(int client) 
{
	SDKHook(client, SDKHook_StartTouch, OnStartTouch);
}

public Action OnStartTouch(int client, int other)
{
	if( other > 0 && other <= MaxClients )
	{
		if( IsClientInGame(client) && IsPlayerAlive(client) )
		{
			float ClientPos[3], VictimPos[3], VictimVecMaxs[3];
			GetClientAbsOrigin(client, ClientPos);
			GetClientAbsOrigin(other, VictimPos);
			GetEntPropVector(other, Prop_Send, "m_vecMaxs", VictimVecMaxs);
			float victimHeight = VictimVecMaxs[2];
			float HeightDiff = ClientPos[2] - VictimPos[2];

			if( HeightDiff > victimHeight )
			{
				float vec[3];
				GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vec);

				if( vec[2] < GetConVarFloat(g_goomba.m_hCvars.StompMinSpeed) * -1.0 )
				{
					if( Goomba_SingleStomp[client] == 0 )
					{
						if( AreValidStompTargets(client, other) )
						{
							int immunityResult = CheckStompImmunity(client, other);

							if( immunityResult == GOOMBA_IMMUNFLAG_NONE )
							{
								if( GoombaStomp(client, other) ) 
								{
									PlayStompReboundSound(client);
									EmitStompParticles(other);
								}
								Goomba_SingleStomp[client] = 1;
								CreateTimer(0.5, SinglStompTimer, client);
							}
							else if( immunityResult & GOOMBA_IMMUNFLAG_VICTIM )
							{
								CPrintToChat(client, "%t", "Victim Immun");
							}
						}
					}
				}
			}
		}
	}

	return Plugin_Continue;
}

bool AreValidStompTargets(int client, int victim)
{
	if( victim <= 0 || victim > MaxClients ) {
		return false;
	
	}
	char edictName[32];
	GetEdictClassname(victim, edictName, sizeof(edictName));

	if( !StrEqual(edictName, "player") ) {
		return false;
	
	}
	if( !IsPlayerAlive(victim) ) {
		return false;
	
	}
	if( GetClientTeam(client) == GetClientTeam(victim) ) {
		if( !GetConVarBool(g_goomba.m_hCvars.FriendlyFire) ||
			!GetConVarBool(FindConVar("mp_friendlyfire")) ||
			GetConVarBool(FindConVar("tf_avoidteammates")) ) {
			return false;
		}
	
	}
	if( GetEntProp(victim, Prop_Data, "m_takedamage", 1) == 0 ) {
		return false;
	
	}
	if( (GetConVarBool(g_goomba.m_hCvars.UberImun) && TF2_IsPlayerInCondition(victim, TFCond_Ubercharged)) ) {
		return false;
	
	}
	if( GetConVarBool(g_goomba.m_hCvars.StunImun ) && TF2_IsPlayerInCondition(victim, TFCond_Dazed) ) {
		return false;
	
	}
	if( GetConVarBool(g_goomba.m_hCvars.CloakImun) && TF2_IsPlayerInCondition(client, TFCond_Cloaked) ) {
		return false;
	
	}
	if( GetConVarBool(g_goomba.m_hCvars.CloakImun) && TF2_IsPlayerInCondition(victim, TFCond_Cloaked) ) {
		return false;
	
	}
	if( GetConVarBool(g_goomba.m_hCvars.BonkedImun) && TF2_IsPlayerInCondition(victim, TFCond_Bonked) ) {
		return false;
	
	}
	return true;
}


public Action SinglStompTimer(Handle timer, any client)
{
	Goomba_SingleStomp[client] = 0;
}

public Action Event_PlayerDeath(Handle event, const char[] name, bool dontBroadcast)
{
	if( GetEventBool(event, "goomba") ) {
		int victim = GetClientOfUserId(GetEventInt(event, "userid"));
		int killer = GetClientOfUserId(GetEventInt(event, "attacker"));

		CPrintToChatAllEx(killer, "%t", "Goomba Stomp", killer, victim);

		int damageBits = GetEventInt(event, "damagebits");

		SetEventString(event, "weapon_logclassname", "goomba");
		SetEventString(event, "weapon", "taunt_scout");
		SetEventInt(event, "damagebits", damageBits |= DMG_ACID);
		SetEventInt(event, "customkill", 0);
		SetEventInt(event, "playerpenetratecount", 0);

		if( !(GetEventInt(event, "death_flags") & TF_DEATHFLAG_DEADRINGER) ) {
			PlayStompSound(victim);
			PrintHintText(victim, "%t", "Victim Stomped");
	   
		}
		if( GetConVarBool(g_goomba.m_hCvars.StompUndisguise) ) {
			TF2_RemovePlayerDisguise(killer);
		
		}
	}
	return Plugin_Continue;
}