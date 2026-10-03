#include "../src/feats/onlinefix.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static int has_exact(char *const e[],const char *w){for(int i=0;e&&e[i];i++)if(!strcmp(e[i],w))return 1;return 0;}
int main(void){
 char *av[]={(char *)"game",(char *)"-onlinefix",NULL}; char *no[]={(char *)"game",NULL};
 char *env[]={(char *)"SteamAppId=123456",(char *)"SteamGameId=123456",(char *)"SteamOverlayGameId=123456",(char *)"PATH=/usr/bin",NULL};
 assert(sx_onlinefix_has_flag(av)); assert(!sx_onlinefix_has_flag(no)); uint32_t id=0;
 assert(sx_onlinefix_find_appid(av,env,&id)&&id==123456); assert(sx_onlinefix_activate(id,"probe"));
 assert(sx_onlinefix_translate_appid(480)==123456); char **rw=sx_onlinefix_rewrite_env(env,id); assert(rw);
 assert(has_exact(rw,"SteamAppId=480")&&has_exact(rw,"SteamGameId=480"));
 assert(has_exact(rw,"SteamOverlayGameId=123456")&&has_exact(rw,"MACSTEAM_ONLINEFIX_APPID=123456"));
 assert(has_exact(rw,"MACSTEAM_ONLINEFIX=1")); sx_onlinefix_free_env(rw); sx_onlinefix_reset(); puts("onlinefix probe: OK"); return 0;
}
