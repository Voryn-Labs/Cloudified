// Packages/CTDLib/Sources/CTDLib/td_json_client.c
// Pure include unit providing module compilation for CTDLib C target without fake fallback implementations.
// Real symbols (td_create_client_id, td_send, td_receive, td_execute) must be resolved by direct linkage
// against the genuine static library closure in build/tdlib/lib/libtdjson.a.
#include "td_json_client.h"
