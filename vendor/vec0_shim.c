#include <sqlite3.h>
int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi);
/* Per-connection registration: works on every platform (incl. Apple, where
   process-global auto_extension is unsupported). */
int mnemo_vec_init(void *db) {
  return sqlite3_vec_init((sqlite3 *)db, 0, 0);
}
