#include "ruby.h"

#define MAX_NUM_OF_PROCS 100

typedef struct ProcEntry {
  char *key;
  VALUE proc;
  struct ProcEntry *next;
} ProcEntry;

typedef struct ProcEntryMap {
  ProcEntry **entries;
} ProcEntryMap;

ProcEntryMap *create_proc_entries();
void set_proc(ProcEntryMap *entryMap, const char *key, VALUE proc);
VALUE get_proc(ProcEntryMap *entryMap, const char *key);
void free_proc_entry_map(ProcEntryMap *entryMap);
