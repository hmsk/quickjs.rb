#include "procs.h"

unsigned int hash(const char *key) {
  unsigned long int value = 0;
  unsigned int i = 0;
  unsigned int key_len = strlen(key);

  for (; i < key_len; ++i) {
    value = value * 37 + key[i];
  }
  return value % MAX_NUM_OF_PROCS;
}

ProcEntry *create_proc_entry(const char *key, VALUE proc) {
  ProcEntry *entry = malloc(sizeof(ProcEntry));
  entry->key = strdup(key);
  entry->proc = proc;
  entry->next = NULL;
  return entry;
}

ProcEntryMap *create_proc_entries() {
  ProcEntryMap *entryMap = malloc(sizeof(ProcEntryMap));
  entryMap->entries = malloc(sizeof(ProcEntry *) * MAX_NUM_OF_PROCS);
  for (int i = 0; i < MAX_NUM_OF_PROCS; ++i) {
    entryMap->entries[i] = NULL;
  }
  return entryMap;
}

void set_proc(ProcEntryMap *entryMap, const char *key, VALUE proc) {
  unsigned int slot = hash(key);
  ProcEntry *entry = entryMap->entries[slot];

  if (entry == NULL) {
    entryMap->entries[slot] = create_proc_entry(key, proc);
    return;
  }

  ProcEntry *prev;
  while (entry != NULL) {
    if (strcmp(entry->key, key) == 0) {
      entry->proc = proc;
      return;
    }
    prev = entry;
    entry = prev->next;
  }

  prev->next = create_proc_entry(key, proc);
}

VALUE get_proc(ProcEntryMap *entryMap, const char *key) {
  unsigned int slot = hash(key);

  ProcEntry *entry = entryMap->entries[slot];

  while (entry != NULL) {
    if (strcmp(entry->key, key) == 0) {
      return entry->proc;
    }
    entry = entry->next;
  }

  return Qnil;
}

void free_proc_entry_map(ProcEntryMap *entryMap) {
  for (int i = 0; i < MAX_NUM_OF_PROCS; ++i) {
    ProcEntry *entry = entryMap->entries[i];
    while (entry != NULL) {
      ProcEntry *temp = entry;
      entry = entry->next;
      free(temp->key);
      free(temp);
    }
  }
  free(entryMap->entries);
  free(entryMap);
}
