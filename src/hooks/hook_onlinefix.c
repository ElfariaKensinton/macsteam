// OnlineFix AppID identity hook
#include "hooks.h"
#include "../feats/onlinefix.h"
#include "../util/log.h"
#include <stdint.h>
static void *orig_GetAppID=NULL;
typedef uint32_t (*fn_GetAppID)(void *self);
static uint32_t hook_GetAppID(void *self){fn_GetAppID orig=(fn_GetAppID)orig_GetAppID;uint32_t result=orig(self);if(sx_hook_passthrough("GetAppID"))return result;uint32_t real=sx_onlinefix_real_appid();if(real&&result==SX_ONLINEFIX_APPID){SX_DBG("[onlinefix] GetAppID: %u -> %u",result,real);return real;}return result;}
static sx_hook_def_t g_hooks[]={{.name="GetAppID",.sig_name="IClientUtils::GetAppID",.hook_fn=(void *)hook_GetAppID,.orig_fn=&orig_GetAppID,.optional=0}};
int sx_hooks_onlinefix_count(void){return(int)(sizeof(g_hooks)/sizeof(g_hooks[0]));}
sx_hook_def_t *sx_hooks_onlinefix_defs(void){return g_hooks;}
