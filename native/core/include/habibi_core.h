#ifndef HABIBI_CORE_H
#define HABIBI_CORE_H

// Borrowed UTF-8 input. Free the owned result exactly once using habibi_core_free.
char *habibi_core_execute(const char *input);
void habibi_core_free(char *output);

#endif
