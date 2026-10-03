// OnlineFix route state and launch-time environment handling
#include "onlinefix.h"
#include "../util/log.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
extern char **environ;
static _Atomic uint32_t g_real_app_id=0;
static int parse_appid(const char *s,uint32_t *out){if(!s||!out||!*s)return 0;while(*s==' '||*s=='\t')s++;if(!isdigit((unsigned char)*s))return 0;char *end=NULL;errno=0;unsigned long long v=strtoull(s,&end,10);if(errno||end==s||v==0||v>0xFFFFFFULL)return 0;while(*end==' '||*end=='\t')end++;if(*end!='\0')return 0;*out=(uint32_t)v;return 1;}
static int dup_into(char **dst,const char *src){size_t n=strlen(src)+1;*dst=malloc(n);if(!*dst)return 0;memcpy(*dst,src,n);return 1;}
static int is_env_key(const char *e,const char *k){size_t n=strlen(k);return e&&strncasecmp(e,k,n)==0&&e[n]=='=';}
static char **effective_env(char *const envp[]){return envp?(char **)envp:environ;}
static int find_argv_appid(char *const argv[],uint32_t *out){if(!argv||!out)return 0;for(int i=0;argv[i];i++){const char *a=argv[i];const char *pfx[]={"-appid=","--appid=","-app_id=","--app-id=","-steamappid=","--steamappid="};for(size_t p=0;p<sizeof(pfx)/sizeof(pfx[0]);p++){size_t n=strlen(pfx[p]);if(strncasecmp(a,pfx[p],n)==0&&parse_appid(a+n,out))return 1;}if(!strcasecmp(a,"-appid")||!strcasecmp(a,"--appid")||!strcasecmp(a,"-app_id")||!strcasecmp(a,"--app-id")||!strcasecmp(a,"-steamappid")||!strcasecmp(a,"--steamappid"))if(argv[i+1]&&parse_appid(argv[i+1],out))return 1;if(!strncasecmp(a,"SteamAppId=",11)&&parse_appid(a+11,out))return 1;}return 0;}
void sx_onlinefix_reset(void){uint32_t old=atomic_exchange_explicit(&g_real_app_id,0,memory_order_acq_rel);if(old)SX_LOG("onlinefix: route cleared (real appid=%u)",old);}
int sx_onlinefix_activate(uint32_t real_app_id,const char *source){if(!real_app_id||real_app_id==SX_ONLINEFIX_APPID)return 0;uint32_t old=atomic_load_explicit(&g_real_app_id,memory_order_acquire);if(old==real_app_id)return 1;atomic_store_explicit(&g_real_app_id,real_app_id,memory_order_release);SX_LOG("onlinefix: route active real_appid=%u source=%s",real_app_id,source?source:"launch");if(old&&old!=real_app_id)SX_WARN("onlinefix: replacing active route %u -> %u",old,real_app_id);return 1;}
int sx_onlinefix_active(void){return atomic_load_explicit(&g_real_app_id,memory_order_acquire)!=0;}
uint32_t sx_onlinefix_real_appid(void){return atomic_load_explicit(&g_real_app_id,memory_order_acquire);}
uint32_t sx_onlinefix_translate_appid(uint32_t app_id){uint32_t real=sx_onlinefix_real_appid();return(real&&app_id==SX_ONLINEFIX_APPID)?real:app_id;}
int sx_onlinefix_has_flag(char *const argv[]){if(!argv)return 0;for(int i=0;argv[i];i++)if(!strcasecmp(argv[i],"-onlinefix")||!strncasecmp(argv[i],"-onlinefix=",11))return 1;return 0;}
int sx_onlinefix_find_appid(char *const argv[],char *const envp[],uint32_t *out){if(!out)return 0;*out=0;char **env=effective_env(envp);const char *keys[]={"SteamAppId","SteamGameId","SteamLaunchAppId","SteamLaunchAppID","STEAM_APP_ID","STEAM_GAME_ID"};for(int i=0;env&&env[i];i++)for(size_t k=0;k<sizeof(keys)/sizeof(keys[0]);k++)if(is_env_key(env[i],keys[k])){uint32_t id=0;if(parse_appid(env[i]+strlen(keys[k])+1,&id)&&id!=SX_ONLINEFIX_APPID){*out=id;return 1;}}return find_argv_appid(argv,out);}
static int set_env_value(char **entry,const char *key,const char *value){size_t n=strlen(key)+strlen(value)+2;char *b=malloc(n);if(!b)return 0;snprintf(b,n,"%s=%s",key,value);free(*entry);*entry=b;return 1;}
char **sx_onlinefix_rewrite_env(char *const envp[],uint32_t real_app_id){if(!real_app_id||real_app_id==SX_ONLINEFIX_APPID)return NULL;char **env=effective_env(envp);if(!env)return NULL;int count=0;while(env[count])count++;char **out=calloc((size_t)count+6,sizeof(char *));if(!out)return NULL;int app=0,game=0,overlay=0,marker=0,route=0;char real[16];snprintf(real,sizeof(real),"%u",real_app_id);for(int i=0;i<count;i++){if(!dup_into(&out[i],env[i]))goto fail;if(is_env_key(env[i],"SteamAppId")){if(!set_env_value(&out[i],"SteamAppId","480"))goto fail;app=1;}else if(is_env_key(env[i],"SteamGameId")){if(!set_env_value(&out[i],"SteamGameId","480"))goto fail;game=1;}else if(is_env_key(env[i],"SteamOverlayGameId")){if(!set_env_value(&out[i],"SteamOverlayGameId",real))goto fail;overlay=1;}else if(is_env_key(env[i],"MACSTEAM_ONLINEFIX_APPID")){if(!set_env_value(&out[i],"MACSTEAM_ONLINEFIX_APPID",real))goto fail;marker=1;}else if(is_env_key(env[i],"MACSTEAM_ONLINEFIX")){if(!set_env_value(&out[i],"MACSTEAM_ONLINEFIX","1"))goto fail;route=1;}}int n=count;char extra[64];if(!app&&!dup_into(&out[n++],"SteamAppId=480"))goto fail;if(!game&&!dup_into(&out[n++],"SteamGameId=480"))goto fail;if(!overlay){snprintf(extra,sizeof(extra),"SteamOverlayGameId=%u",real_app_id);if(!dup_into(&out[n++],extra))goto fail;}if(!marker){snprintf(extra,sizeof(extra),"MACSTEAM_ONLINEFIX_APPID=%u",real_app_id);if(!dup_into(&out[n++],extra))goto fail;}if(!route&&!dup_into(&out[n++],"MACSTEAM_ONLINEFIX=1"))goto fail;out[n]=NULL;SX_LOG("onlinefix: child environment prepared real=%u app/game=480 overlay=%u",real_app_id,real_app_id);return out;fail:sx_onlinefix_free_env(out);return NULL;}
void sx_onlinefix_free_env(char **envp){if(!envp)return;for(int i=0;envp[i];i++)free(envp[i]);free(envp);}
