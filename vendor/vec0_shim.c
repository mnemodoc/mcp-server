#include <sqlite3.h>
int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi);
/* Per-connection registration: works on every platform (incl. Apple, where
   process-global auto_extension is unsupported). */
int mnemo_vec_init(void *db) {
  /* sqlite3_vec_init writes to *pzErrMsg on every one of its failure paths
     without checking it first (sqlite-vec.c, the create_function_v2 and
     create_module_v2 loops), so passing NULL turns a recoverable error —
     SQLITE_NOMEM, or another extension already owning the "vec0" module name —
     into a write to address zero. That crash would land in setup_connection,
     for every connection the pool opens, instead of the return code the caller
     expects. The message is ours to free once read. */
  char *err = 0;
  int rc = sqlite3_vec_init((sqlite3 *)db, &err, 0);
  if (err) {
    sqlite3_free(err);
  }
  return rc;
}
