#ifndef SPINEL_BACKEND_IR_H
#define SPINEL_BACKEND_IR_H

#include "compiler.h"

/* Serialize the post-analysis NodeTable and the backend-relevant portion of
   Compiler as deterministic, versioned JSON.  The caller owns the result. */
char *backend_ir_json(const Compiler *c);
/* Preserve lexical blocks/control flow before native-specific desugaring. */
char *backend_syntax_json(const NodeTable *nt);

#endif
