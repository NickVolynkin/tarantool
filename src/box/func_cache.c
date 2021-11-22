/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2010-2021, Tarantool AUTHORS, please see AUTHORS file.
 */
#include "func_cache.h"

#include <assert.h>
#include "assoc.h"

static struct mh_i32ptr_t *funcs;
/**
 * Hash tuple for func name to a ring list of subscriptions.
 * If at least one subscription exist for a name the (an only then) there's
 * a node in this table with `val` member pointing to one of subscriptions
 * (that is struct func_cache_subscription). Several subscriptions with the
 * same name are linked via `link` member.
 */
static struct mh_i32ptr_t *pinned_funcs;
static struct mh_strnptr_t *funcs_by_name;

const char *func_cache_holder_type_strs[HOLDER_TYPE_MAX] = {
	"constraint",
};

void
func_cache_init()
{
	funcs = mh_i32ptr_new();
	pinned_funcs = mh_i32ptr_new();
	funcs_by_name = mh_strnptr_new();
}

void
func_cache_destroy()
{
	while (mh_size(funcs) > 0) {
		mh_int_t i = mh_first(funcs);

		struct func *func = ((struct func *)
			mh_i32ptr_node(funcs, i)->val);
		func_cache_delete(func->def->fid);
		func_delete(func);
	}
	mh_i32ptr_delete(funcs);
	mh_i32ptr_delete(pinned_funcs);
	mh_strnptr_delete(funcs_by_name);
}

void
func_cache_insert(struct func *func)
{
	assert(func_by_id(func->def->fid) == NULL);
	assert(func_by_name(func->def->name, strlen(func->def->name)) == NULL);
	const struct mh_i32ptr_node_t node = { func->def->fid, func };
	mh_i32ptr_put(funcs, &node, NULL, NULL);
	size_t def_name_len = strlen(func->def->name);
	uint32_t name_hash = mh_strn_hash(func->def->name, def_name_len);
	const struct mh_strnptr_node_t strnode = {
		func->def->name, def_name_len, name_hash, func };
	mh_strnptr_put(funcs_by_name, &strnode, NULL, NULL);
}

void
func_cache_delete(uint32_t fid)
{
	assert(mh_i32ptr_find(pinned_funcs, fid, NULL) == mh_end(pinned_funcs));
	mh_int_t k = mh_i32ptr_find(funcs, fid, NULL);
	if (k == mh_end(funcs))
		return;
	struct func *func = (struct func *) mh_i32ptr_node(funcs, k)->val;
	mh_i32ptr_del(funcs, k, NULL);
	k = mh_strnptr_find_str(funcs_by_name, func->def->name,
				strlen(func->def->name));
	if (k != mh_end(funcs))
		mh_strnptr_del(funcs_by_name, k, NULL);
}

struct func *
func_by_id(uint32_t fid)
{
	mh_int_t func = mh_i32ptr_find(funcs, fid, NULL);
	if (func == mh_end(funcs))
		return NULL;
	return (struct func *) mh_i32ptr_node(funcs, func)->val;
}

struct func *
func_by_name(const char *name, uint32_t name_len)
{
	mh_int_t func = mh_strnptr_find_str(funcs_by_name, name, name_len);
	if (func == mh_end(funcs_by_name))
		return NULL;
	return (struct func *) mh_strnptr_node(funcs_by_name, func)->val;
}

void
func_cache_pin(struct func *func, struct func_cache_holder *holder,
	       enum func_cache_holder_type type)
{
	holder->type = type;
	uint32_t fid = func->def->fid;
	assert(mh_i32ptr_find(funcs, fid, NULL) != mh_end(funcs));

	mh_int_t pos = mh_i32ptr_find(pinned_funcs, fid, NULL);
	if (pos == mh_end(pinned_funcs)) {
		/* No holders yet. The new ring will consist of one holder. */
		rlist_create(&holder->link);
		const struct mh_i32ptr_node_t new_node = {fid, holder};
		mh_i32ptr_put(pinned_funcs, &new_node, NULL, NULL);
	} else {
		/* There are some holders. Add to their ring. */
		struct func_cache_holder *another = mh_i32ptr_node(pinned_funcs,
								   pos)->val;
		assert(another != NULL);
		rlist_add_tail(&another->link, &holder->link);
	}
}

void
func_cache_unpin(struct func *func, struct func_cache_holder *holder)
{
	uint32_t fid = func->def->fid;
	assert(mh_i32ptr_find(funcs, fid, NULL) != mh_end(funcs));

	mh_int_t pos = mh_i32ptr_find(pinned_funcs, fid, NULL);
	assert(pos != mh_end(pinned_funcs));
	struct mh_i32ptr_node_t *node = mh_i32ptr_node(pinned_funcs, pos);

	if (rlist_empty(&holder->link)) {
		/* This is the last element of the ring. Delete entry. */
		mh_i32ptr_del(pinned_funcs, pos, NULL);
	} else {
		/* There are more holders, need to remove holder from ring. */
		if (node->val == holder) {
			/* Also need need to repoint to some other holder. */
			struct func_cache_holder *next =
				rlist_next_entry(holder, link);
			const struct mh_i32ptr_node_t new_node = { fid, next };
			mh_i32ptr_put(pinned_funcs, &new_node, NULL, NULL);
		}
		rlist_del(&holder->link);
	}
}

bool
func_cache_is_pinned(struct func *func, enum func_cache_holder_type *type)
{
	assert(mh_i32ptr_find(funcs, func->def->fid, NULL) != mh_end(funcs));
	mh_int_t pos = mh_i32ptr_find(pinned_funcs, func->def->fid, NULL);
	if (pos == mh_end(pinned_funcs))
		return false;
	struct mh_i32ptr_node_t *node = mh_i32ptr_node(pinned_funcs, pos);
	struct func_cache_holder *holder = node->val;
	*type = holder->type;
	return true;
}
