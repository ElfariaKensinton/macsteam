// OnlineFix route state and launch helpers
#ifndef MACSTEAM_FEATS_ONLINEFIX_H
#define MACSTEAM_FEATS_ONLINEFIX_H
#include <stdint.h>
#define SX_ONLINEFIX_APPID 480u
void sx_onlinefix_reset(void);
int sx_onlinefix_activate(uint32_t real_app_id,const char *source);
int sx_onlinefix_active(void);
uint32_t sx_onlinefix_real_appid(void);
uint32_t sx_onlinefix_translate_appid(uint32_t app_id);
int sx_onlinefix_has_flag(char *const argv[]);
int sx_onlinefix_find_appid(char *const argv[],char *const envp[],uint32_t *out_app_id);
char **sx_onlinefix_rewrite_env(char *const envp[],uint32_t real_app_id);
void sx_onlinefix_free_env(char **envp);
#endif
