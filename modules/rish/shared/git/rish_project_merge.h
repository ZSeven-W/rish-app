// Merging a diverged branch with its upstream, for the Git panel: the part
// both hosts share. Android wraps it in JNI (rish_project_merge.cpp under
// apps/mobile/android/app/src/main/cpp); iOS includes the implementation
// from LocalProjectsModule.mm and hands it the repository its write lease
// already holds.
//
// Every function borrows the repository -- it neither opens nor frees it --
// and answers one JSON object as a string. The journal, the lease and the
// error codes the person sees belong to each host.
//
// Only a clean merge is ever carried out. A merge with a conflict is refused
// with the conflicting paths and nothing about the repository moves: no
// conflict markers, no MERGE_HEAD, no index or working-tree change, no ref.
// `git_merge_commits` may still leave unreferenced blobs in the object
// database, which is harmless; the promise is about refs, index, working
// tree and merge state.
//
// The work is split so the caller can journal between the part that only
// decides and the part that changes files:
//
//   Prepare  every precondition, the merge in memory, the merge commit
//            object (referenced by nothing), and a dry-run checkout.
//            Changes no ref, index or working tree.
//   Apply    checks the merged tree out over the recorded baseline, then
//            moves the branch with a compare-and-swap.
//   MoveRef  the compare-and-swap alone, for a recovery that finds the
//            checkout already done.
//   Inspect  what the branch, the index and the working tree are now, so
//            recovery decides from facts rather than from a phase that may
//            have been written before its effect.
//
// Every checkout here uses GIT_CHECKOUT_DONT_OVERWRITE_IGNORED: SAFE alone
// writes over a file the person keeps out of Git.

#pragma once

#include <git2.h>

#include <string>

namespace rish {
namespace merge {

/// `{"ok":true,"outcome":…}` with one of ready | up_to_date |
/// fast_forward_available | conflicts | obstructed | detached_head |
/// unborn_head | head_changed | operation_in_progress | shallow |
/// no_upstream | upstream_changed | unrelated_histories | dirty |
/// unsupported_submodule | unsupported_filter | unsupported_paths, or
/// `{"ok":false,"code":…,"stage":…,"error":…}`. `ready` carries merge_oid,
/// tree_oid, ours, theirs; `conflicts` the conflicting entries
/// `[{ancestor, ours, theirs}]`; `obstructed` the paths in the way.
std::string Prepare(git_repository *repository, const std::string &branch, const std::string &expectedHead,
                    const std::string &expectedTheirs, const std::string &name, const std::string &email);

/// merged | head_changed | obstructed | checkout_failed | ref_changed |
/// ref_failed. Only head_changed and obstructed promise nothing was written.
std::string Apply(git_repository *repository, const std::string &branch, const std::string &ours,
                  const std::string &merge);

/// The compare-and-swap alone: merged | ref_changed | ref_failed.
std::string MoveRef(git_repository *repository, const std::string &branch, const std::string &ours,
                    const std::string &merge);

/// `{"ok":true,"head":"ours"|"merge"|"other","index_ours":bool,
/// "index_merge":bool,"worktree_clean":bool,"conflicted":bool}`. The index
/// is re-read from disk first. Both index flags are true when the merge's
/// tree is the tree the branch already had -- the same change made on both
/// sides -- so a caller must never read "matches ours" as "not merged".
std::string Inspect(git_repository *repository, const std::string &branch, const std::string &ours,
                    const std::string &merge);

}  // namespace merge
}  // namespace rish
