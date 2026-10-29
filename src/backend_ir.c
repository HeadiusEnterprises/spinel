#include "backend_ir.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Growable JSON output; serialization never transfers compiler-owned data. */
typedef struct {
  char *data;
  size_t length, capacity;
} JsonBuffer;

static void json_reserve(JsonBuffer *buffer, size_t extra) {
  size_t need = buffer->length + extra + 1;
  if (need <= buffer->capacity)
    return;
  size_t cap = buffer->capacity ? buffer->capacity : 4096;
  while (cap < need)
    cap *= 2;
  buffer->data = realloc(buffer->data, cap);
  if (!buffer->data) {
    fprintf(stderr, "spinel: out of memory emitting backend IR\n");
    exit(1);
  }
  buffer->capacity = cap;
}

static void json_append_bytes(JsonBuffer *buffer, const char *s, size_t n) {
  json_reserve(buffer, n);
  memcpy(buffer->data + buffer->length, s, n);
  buffer->length += n;
  buffer->data[buffer->length] = 0;
}

static void json_append(JsonBuffer *buffer, const char *s) {
  json_append_bytes(buffer, s, strlen(s));
}

static void json_integer(JsonBuffer *buffer, long long v) {
  char tmp[64];
  int n = snprintf(tmp, sizeof tmp, "%lld", v);
  json_append_bytes(buffer, tmp, (size_t)n);
}

static void json_string_bytes(JsonBuffer *buffer, const char *s, size_t n) {
  static const char hex[] = "0123456789abcdef";
  json_append(buffer, "\"");
  for (size_t i = 0; i < n; i++) {
    unsigned char ch = (unsigned char)s[i];
    if (ch == '"')
      json_append(buffer, "\\\"");
    else if (ch == '\\')
      json_append(buffer, "\\\\");
    else if (ch == '\n')
      json_append(buffer, "\\n");
    else if (ch == '\r')
      json_append(buffer, "\\r");
    else if (ch == '\t')
      json_append(buffer, "\\t");
    else if (ch < 0x20) {
      char esc[6] = {'\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 15]};
      json_append_bytes(buffer, esc, sizeof esc);
    } else
      json_append_bytes(buffer, (const char *)&s[i], 1);
  }
  json_append(buffer, "\"");
}

static void json_string(JsonBuffer *buffer, const char *s) {
  if (!s)
    json_append(buffer, "null");
  else
    json_string_bytes(buffer, s, strlen(s));
}

char *backend_syntax_json(const NodeTable *nodes) {
  JsonBuffer buffer = {0};
  json_append(&buffer, "{\"root\":");
  json_integer(&buffer, nodes->root_id);
  json_append(&buffer, ",\"nodes\":[");
  for (int id = 0; id < nodes->count; id++) {
    const SpNode *n = &nodes->nodes[id];
    if (id)
      json_append(&buffer, ",");
    json_append(&buffer, "{\"id\":");
    json_integer(&buffer, id);
    json_append(&buffer, ",\"kind\":");
    json_string(&buffer, n->type);
    json_append(&buffer, ",\"content\":");
    json_string(&buffer, n->content);
    json_append(&buffer, ",\"strings\":{");
    for (int j = 0; j < n->ns; j++) {
      if (j)
        json_append(&buffer, ",");
      json_string(&buffer, n->s[j].key);
      json_append(&buffer, ":");
      json_string_bytes(&buffer, n->s[j].val, n->s[j].val_len);
    }
    json_append(&buffer, "},\"integers\":{");
    for (int j = 0; j < n->ni; j++) {
      if (j)
        json_append(&buffer, ",");
      json_string(&buffer, n->i[j].key);
      json_append(&buffer, ":");
      json_integer(&buffer, n->i[j].val);
    }
    json_append(&buffer, "},\"references\":{");
    for (int j = 0; j < n->nr; j++) {
      if (j)
        json_append(&buffer, ",");
      json_string(&buffer, n->r[j].key);
      json_append(&buffer, ":");
      json_integer(&buffer, n->r[j].ref);
    }
    json_append(&buffer, "},\"arrays\":{");
    for (int j = 0; j < n->na; j++) {
      if (j)
        json_append(&buffer, ",");
      json_string(&buffer, n->a[j].key);
      json_append(&buffer, ":[");
      for (int k = 0; k < n->a[j].n; k++) {
        if (k)
          json_append(&buffer, ",");
        json_integer(&buffer, n->a[j].ids[k]);
      }
      json_append(&buffer, "]");
    }
    json_append(&buffer, "}}");
  }
  json_append(&buffer, "]}");
  return buffer.data;
}

static void emit_type(JsonBuffer *buffer, TyKind t) {
  if (ty_is_object(t)) {
    json_append(buffer, "\"object:");
    json_integer(buffer, ty_object_class(t));
    json_append(buffer, "\"");
  } else if (ty_is_obj_array(t)) {
    json_append(buffer, "\"object_array:");
    json_integer(buffer, ty_obj_array_class(t));
    json_append(buffer, "\"");
  } else
    json_string(buffer, ty_name(t));
}

static void emit_local(JsonBuffer *buffer, const LocalVar *local) {
  json_append(buffer, "{\"name\":");
  json_string(buffer, local->name);
  json_append(buffer, ",\"type\":");
  emit_type(buffer, local->type);
  json_append(buffer, ",\"parameter\":");
  json_append(buffer, local->is_param ? "true" : "false");
  json_append(buffer, ",\"block_parameter\":");
  json_append(buffer, local->is_block_param ? "true" : "false");
  json_append(buffer, ",\"captured\":");
  json_append(buffer, local->is_cell ? "true" : "false");
  json_append(buffer, ",\"byref_out\":");
  json_append(buffer, local->byref_out ? "true" : "false");
  json_append(buffer, ",\"nullable_int\":");
  json_append(buffer, local->nullable_int ? "true" : "false");
  json_append(buffer, ",\"nullable_element\":");
  json_append(buffer, local->nullable_int_elem ? "true" : "false");
  json_append(buffer, ",\"array_or_nil\":");
  json_append(buffer, local->arr_or_nil ? "true" : "false");
  json_append(buffer, ",\"shared_string\":");
  json_append(buffer, local->str_shared ? "true" : "false");
  json_append(buffer, ",\"append_string\":");
  json_append(buffer, local->str_append ? "true" : "false");
  json_append(buffer, ",\"proc_return_type\":");
  emit_type(buffer, (TyKind)local->proc_ret);
  json_append(buffer, "}");
}

static void emit_named_locals(JsonBuffer *buffer, const LocalVar *vars, int count) {
  json_append(buffer, "[");
  for (int i = 0; i < count; i++) {
    if (i)
      json_append(buffer, ",");
    emit_local(buffer, &vars[i]);
  }
  json_append(buffer, "]");
}

char *backend_ir_json(const Compiler *compiler) {
  const NodeTable *nodes = compiler->nt;
  JsonBuffer buffer = {0};
  json_append(&buffer, "{\n\"format\":\"SPINEL-ANALYZED-IR\",\n\"version\":1,");
  json_append(&buffer, "\n\"root\":");
  json_integer(&buffer, nodes->root_id);
  json_append(&buffer, ",\n\"source_file\":");
  json_string(&buffer, nodes->source_file);
  json_append(&buffer, ",\n\"files\":[");
  for (int i = 0; i < nodes->nfiles; i++) {
    if (i)
      json_append(&buffer, ",");
    json_string(&buffer, nodes->files[i]);
  }
  json_append(&buffer, "],\n\"nodes\":[\n");

  for (int id = 0; id < nodes->count; id++) {
    const SpNode *n = &nodes->nodes[id];
    if (id)
      json_append(&buffer, ",\n");
    json_append(&buffer, "{\"id\":");
    json_integer(&buffer, id);
    json_append(&buffer, ",\"kind\":");
    json_string(&buffer, n->type);
    json_append(&buffer, ",\"content\":");
    json_string(&buffer, n->content);
    json_append(&buffer, ",\"strings\":{");
    for (int j = 0; j < n->ns; j++) {
      if (j)
        json_append(&buffer, ",");
      json_string(&buffer, n->s[j].key);
      json_append(&buffer, ":");
      json_string_bytes(&buffer, n->s[j].val, n->s[j].val_len);
    }
    json_append(&buffer, "},\"integers\":{");
    for (int j = 0; j < n->ni; j++) {
      if (j)
        json_append(&buffer, ",");
      json_string(&buffer, n->i[j].key);
      json_append(&buffer, ":");
      json_integer(&buffer, n->i[j].val);
    }
    json_append(&buffer, "},\"references\":{");
    for (int j = 0; j < n->nr; j++) {
      if (j)
        json_append(&buffer, ",");
      json_string(&buffer, n->r[j].key);
      json_append(&buffer, ":");
      json_integer(&buffer, n->r[j].ref);
    }
    json_append(&buffer, "},\"arrays\":{");
    for (int j = 0; j < n->na; j++) {
      if (j)
        json_append(&buffer, ",");
      json_string(&buffer, n->a[j].key);
      json_append(&buffer, ":[");
      for (int k = 0; k < n->a[j].n; k++) {
        if (k)
          json_append(&buffer, ",");
        json_integer(&buffer, n->a[j].ids[k]);
      }
      json_append(&buffer, "]");
    }
    json_append(&buffer, "},\"analysis\":{\"type\":");
    emit_type(&buffer, comp_ntype(compiler, id));
    json_append(&buffer, ",\"scope\":");
    json_integer(&buffer, compiler->nscope[id]);
    json_append(&buffer, ",\"class_body\":");
    json_integer(&buffer, compiler->node_cbody[id]);
    json_append(&buffer, ",\"nil_narrow\":");
    emit_type(&buffer, compiler->nilnarrow[id]);
    json_append(&buffer, ",\"string_handle\":");
    json_append(&buffer, compiler->strbuf_handle_demand[id] ? "true" : "false");
    json_append(&buffer, ",\"array_want\":");
    emit_type(&buffer, compiler->arr_want[id]);
    json_append(&buffer, ",\"hash_want\":");
    emit_type(&buffer, compiler->hash_want[id]);
    json_append(&buffer, "}}");
  }

  json_append(&buffer, "\n],\n\"scopes\":[");
  for (int i = 0; i < compiler->nscopes; i++) {
    const Scope *s = &compiler->scopes[i];
    if (i)
      json_append(&buffer, ",");
    json_append(&buffer, "{\"id\":");
    json_integer(&buffer, i);
    json_append(&buffer, ",\"name\":");
    json_string(&buffer, s->name);
    json_append(&buffer, ",\"definition\":");
    json_integer(&buffer, s->def_node);
    json_append(&buffer, ",\"body\":");
    json_integer(&buffer, s->body);
    json_append(&buffer, ",\"class\":");
    json_integer(&buffer, s->class_id);
    json_append(&buffer, ",\"return_type\":");
    emit_type(&buffer, s->ret);
    json_append(&buffer, ",\"nullable_return\":");
    json_append(&buffer, s->ret_nullable_int ? "true" : "false");
    json_append(&buffer, ",\"yielding\":");
    json_append(&buffer, s->yields ? "true" : "false");
    json_append(&buffer, ",\"reachable\":");
    json_append(&buffer, s->reachable ? "true" : "false");
    json_append(&buffer, ",\"class_method\":");
    json_append(&buffer, s->is_cmethod ? "true" : "false");
    json_append(&buffer, ",\"parameters\":[");
    for (int p = 0; p < s->nparams; p++) {
      if (p)
        json_append(&buffer, ",");
      json_append(&buffer, "{\"name\":");
      json_string(&buffer, s->pnames[p]);
      json_append(&buffer, ",\"default\":");
      json_integer(&buffer, s->pdefault ? s->pdefault[p] : -1);
      json_append(&buffer, "}");
    }
    json_append(&buffer, "],\"locals\":");
    emit_named_locals(&buffer, s->locals, s->nlocals);
    json_append(&buffer, "}");
  }

  json_append(&buffer, "],\n\"classes\":[");
  for (int i = 0; i < compiler->nclasses; i++) {
    const ClassInfo *ci = &compiler->classes[i];
    if (i)
      json_append(&buffer, ",");
    json_append(&buffer, "{\"id\":");
    json_integer(&buffer, i);
    json_append(&buffer, ",\"name\":");
    json_string(&buffer, ci->name);
    json_append(&buffer, ",\"definition\":");
    json_integer(&buffer, ci->def_node);
    json_append(&buffer, ",\"parent\":");
    json_integer(&buffer, ci->parent);
    json_append(&buffer, ",\"value_type\":");
    json_append(&buffer, ci->is_value_type ? "true" : "false");
    json_append(&buffer, ",\"ivars\":[");
    for (int j = 0; j < ci->nivars; j++) {
      if (j)
        json_append(&buffer, ",");
      json_append(&buffer, "{\"name\":");
      json_string(&buffer, ci->ivars[j]);
      json_append(&buffer, ",\"type\":");
      emit_type(&buffer, ci->ivar_types[j]);
      json_append(&buffer, ",\"nullable_int\":");
      json_append(&buffer, ci->ivar_nullable_int && ci->ivar_nullable_int[j] ? "true" : "false");
      json_append(&buffer, "}");
    }
    json_append(&buffer, "]}");
  }

  json_append(&buffer, "],\n\"symbols\":[");
  for (int i = 0; i < compiler->nsymbols; i++) {
    if (i)
      json_append(&buffer, ",");
    json_string_bytes(&buffer, compiler->symbols[i], compiler->symbol_lens[i]);
  }
  json_append(&buffer, "],\n\"globals\":");
  emit_named_locals(&buffer, compiler->gvars, compiler->ngvars);
  json_append(&buffer, ",\n\"constants\":");
  emit_named_locals(&buffer, compiler->consts, compiler->nconsts);
  json_append(&buffer, ",\n\"features\":[");
  for (int i = 0; i < sp_feature_count(); i++) {
    if (i)
      json_append(&buffer, ",");
    json_string(&buffer, sp_feature_name(i));
  }
  json_append(&buffer, "]");
  json_append(&buffer, ",\n\"native_dependencies\":{\"ffi_functions\":");
  json_integer(&buffer, compiler->n_ffi_funcs);
  json_append(&buffer, ",\"native_functions\":");
  json_integer(&buffer, compiler->n_native_funcs);
  json_append(&buffer, ",\"native_methods\":");
  json_integer(&buffer, compiler->n_native_methods);
  json_append(&buffer, "}\n}\n");
  return buffer.data;
}
