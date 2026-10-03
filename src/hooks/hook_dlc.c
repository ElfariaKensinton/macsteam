// DLC hooks
#include "hooks.h"
#include "../feats/dlc.h"
#include "../core/ctx.h"
#include "../feats/onlinefix.h"
#include <stdint.h>

void sx_hooks_ctx_set_helpers(uintptr_t getappid) {
    sx_ctx_set_getappid(getappid);
}

static void *orig_IsAppDlcInstalled = NULL;
typedef int (*fn_IsAppDlcInstalled)(void *self, uint32_t app_id, uint32_t dlc_id);

static int hook_IsAppDlcInstalled(void *self, uint32_t app_id, uint32_t dlc_id) {
    fn_IsAppDlcInstalled orig = (fn_IsAppDlcInstalled)orig_IsAppDlcInstalled;
    uint32_t query_app_id = sx_onlinefix_translate_appid(app_id);
    int result = orig(self, query_app_id, dlc_id);

    return sx_dlc_is_installed(self, query_app_id, dlc_id, result);
}


static void *orig_BGetDLCDataByIndex = NULL;
typedef int (*fn_BGetDLCDataByIndex)(void *self, uint32_t app_id, int index,
                                     uint32_t *pDlcId, int *pAvailable,
                                     char *pName, int nameLen);

static int hook_BGetDLCDataByIndex(void *self, uint32_t app_id, int index,
                                    uint32_t *pDlcId, int *pAvailable,
                                    char *pName, int nameLen) {
    fn_BGetDLCDataByIndex orig = (fn_BGetDLCDataByIndex)orig_BGetDLCDataByIndex;
    uint32_t query_app_id = sx_onlinefix_translate_appid(app_id);
    int result = orig(self, query_app_id, index, pDlcId, pAvailable, pName, nameLen);

    return sx_dlc_force_available(self, query_app_id, index, pDlcId, pAvailable, result);
}


static void *orig_IsUserSubscribedAppInTicket = NULL;
typedef int (*fn_IsUserSubscribedAppInTicket)(void *self, uint64_t steam_id,
                                              uint32_t app_id);

static int hook_IsUserSubscribedAppInTicket(void *self, uint64_t steam_id,
                                            uint32_t app_id) {
    fn_IsUserSubscribedAppInTicket orig =
        (fn_IsUserSubscribedAppInTicket)orig_IsUserSubscribedAppInTicket;
    uint32_t query_app_id = sx_onlinefix_translate_appid(app_id);
    int result = orig(self, steam_id, query_app_id);

    return sx_dlc_user_subscribed_in_ticket(self, query_app_id, result);
}


static sx_hook_def_t g_hooks[] = {
    {
        .name     = "IsAppDlcInstalled",
        .sig_name = "IClientAppManager::IsAppDlcInstalled",
        .hook_fn  = (void *)hook_IsAppDlcInstalled,
        .orig_fn  = &orig_IsAppDlcInstalled,
        .optional = 1,
    },
    {
        .name     = "BGetDLCDataByIndex",
        .sig_name = "IClientApps::BGetDLCDataByIndex",
        .hook_fn  = (void *)hook_BGetDLCDataByIndex,
        .orig_fn  = &orig_BGetDLCDataByIndex,
        .optional = 1,
    },
    {
        .name     = "IsUserSubscribedAppInTicket",
        .sig_name = "IClientUser::IsUserSubscribedAppInTicket",
        .hook_fn  = (void *)hook_IsUserSubscribedAppInTicket,
        .orig_fn  = &orig_IsUserSubscribedAppInTicket,
        .optional = 1,
    },
};

int sx_hooks_dlc_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

sx_hook_def_t *sx_hooks_dlc_defs(void) {
    return g_hooks;
}
