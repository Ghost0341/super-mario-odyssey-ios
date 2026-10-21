// Save observers run only after real successful transactions and under both locks.
#include <sys/clonefile.h>
#include <stdio.h>
#include <errno.h>
static int test_clone(const char *, const char *, int);
static int test_swap(const char *, const char *, unsigned);
#define clonefile test_clone
#define renamex_np test_swap
#include "../hle_fs.c"
#undef clonefile
#undef renamex_np

struct dm_flags g_flag; uint64_t g_t0_ns;
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
void dm_prof_add(int id, uint64_t ns, uint64_t b) { (void)id; (void)ns; (void)b; }
void dm_guest_write_prepare(void *a, size_t n) { (void)a; (void)n; }
static int checks, failures, notifications, fail_clone, fail_swap;
static const char *expected_directory, *expected_contents;
#define CHECK(test, message) do { checks++; if (!(test)) { failures++; fprintf(stderr, "FAIL: %s\n", message); } } while (0)
static int test_clone(const char *a, const char *b, int flags) {
    if (fail_clone) { errno = ENOSPC; return -1; } return clonefile(a, b, flags);
}
static int test_swap(const char *a, const char *b, unsigned flags) {
    if (fail_swap) { errno = EIO; return -1; } return renamex_np(a, b, flags);
}
static int same(const char *directory, const char *value) {
    char path[1400], bytes[64] = {0}; snprintf(path, sizeof path, "%s/a", directory);
    FILE *file = fopen(path, "r"); if (!file) return 0;
    size_t n = fread(bytes, 1, sizeof bytes, file); fclose(file);
    return n == strlen(value) && !memcmp(bytes, value, n);
}
// Called by the separate strong implementation, just as the real iOS front end.
void dm_test_commit_callback(const char *directory) {
    notifications++;
    int mount_lock = pthread_mutex_trylock(&g_lock), path_lock = pthread_mutex_trylock(&g_path_lock);
    CHECK(mount_lock == EBUSY && path_lock == EBUSY, "callback sees both transaction locks held");
    if (!mount_lock) pthread_mutex_unlock(&g_lock);
    if (!path_lock) pthread_mutex_unlock(&g_path_lock);
    CHECK(expected_directory && !strcmp(directory, expected_directory), "callback receives committed directory, never work/new");
    CHECK(expected_contents && same(directory, expected_contents), "synchronous callback reads the exact published bytes");
}
static void put(const char *directory, const char *value) {
    char path[1400]; snprintf(path, sizeof path, "%s/a", directory);
    FILE *file = fopen(path, "w"); if (!file) abort(); fputs(value, file); fclose(file);
}
static Result write_save(const char *value) {
    uint64_t h; Result result = h_fs_OpenFile(&h, "save:/a", MODE_WRITE);
    if (result) return result;
    result = h_fs_SetFileSize(h, (int64_t)strlen(value));
    if (!result) result = h_fs_WriteFile(h, 0, value, strlen(value), NULL);
    h_fs_CloseFile(h); return result;
}
static void notified(int before, int successful_transactions) {
#if TARGET_OS_IPHONE || defined(DM_TEST_SAVE_COMMIT)
    CHECK(notifications == before + successful_transactions, "one callback per successful real transaction");
#else
    (void)successful_transactions;
    CHECK(notifications == before, "non-iOS host skips save callbacks");
#endif
}
int main(void) {
    unsetenv("DM_TEST_FS_FAIL"); unsetenv("DM_TEST_FS_FAILAT");
    char root[] = "/private/tmp/dm-save-commit.XXXXXX", save[1200], other[1200], cache[1200];
    CHECK(mkdtemp(root) != NULL, "temporary fixture root");
    snprintf(save, sizeof save, "%s/save", root); CHECK(!mkdir(save, 0700), "committed fixture directory");
    put(save, "old"); setenv("DM_SAVE", save, 1); expected_directory = save;
    CHECK(h_fs_MountSave("save", NULL) == RES_OK, "transactional save mount");
    int n = notifications; expected_contents = "single";
    CHECK(write_save("single") == RES_OK && h_fs_Commit("save") == RES_OK, "single-name Commit publishes"); notified(n, 1);
    const char *one[] = {"save"}, *duplicates[] = {"save", "save"}, *unknown[] = {"save", "missing"};
    n = notifications; expected_contents = "list";
    CHECK(write_save("list") == RES_OK && h_fs_CommitList(one, 1) == RES_OK, "mount-list Commit publishes"); notified(n, 1);
    n = notifications; expected_contents = "duplicates";
    CHECK(write_save("duplicates") == RES_OK && h_fs_CommitList(duplicates, 2) == RES_OK, "duplicate list commits once"); notified(n, 1);
    n = notifications;
    CHECK(h_fs_Commit("absent") == RES_OK && h_fs_CommitList(NULL, 0) == RES_OK, "successful no-op commits");
    CHECK(h_fs_CommitList(unknown, 2) != RES_OK && h_fs_CommitList(NULL, 1) != RES_OK, "invalid list refuses without a transaction"); notified(n, 0);
    CHECK(write_save("poisoned-single") == RES_OK, "stage rejected single transaction"); save_poison(ENOSPC);
    CHECK(h_fs_Commit("save") != RES_OK && same(save, "duplicates"), "poisoned single Commit preserves old save"); notified(n, 0);
    expected_contents = "single-retry";
    CHECK(write_save(expected_contents) == RES_OK && h_fs_Commit("save") == RES_OK, "clean single retry publishes"); notified(n, 1);
    n = notifications;
    CHECK(write_save("poisoned-list") == RES_OK, "stage rejected list transaction"); save_poison(ENOSPC);
    CHECK(h_fs_CommitList(one, 1) != RES_OK && same(save, "single-retry"), "poisoned list Commit preserves old save"); notified(n, 0);
    expected_contents = "list-retry";
    CHECK(write_save(expected_contents) == RES_OK && h_fs_CommitList(one, 1) == RES_OK, "clean list retry publishes"); notified(n, 1);
    n = notifications; CHECK(write_save("pending") == RES_OK, "stage failing publication");
    fail_clone = 1; CHECK(h_fs_Commit("save") != RES_OK && same(save, "list-retry"), "clone failure is not a commit"); fail_clone = 0; notified(n, 0);
    fail_swap = 1; CHECK(h_fs_CommitList(one, 1) != RES_OK && same(save, "list-retry"), "swap failure is not a commit"); fail_swap = 0; notified(n, 0);
    expected_contents = "pending"; CHECK(h_fs_CommitList(one, 1) == RES_OK, "failed publication can retry"); notified(n, 1);
    n = notifications;
    snprintf(cache, sizeof cache, "%s/cache", root); CHECK(!mkdir(cache, 0700) && mount("cache", cache, 0) == RES_OK, "non-transactional mount");
    const char *cache_only[] = {"cache"};
    CHECK(h_fs_Commit("cache") == RES_OK && h_fs_CommitList(cache_only, 1) == RES_OK, "cache commits have no published save tree"); notified(n, 0);
    snprintf(other, sizeof other, "%s/other", root); CHECK(!mkdir(other, 0700), "independent save fixture"); put(other, "other");
    setenv("DM_SAVE", other, 1); CHECK(h_fs_MountSave("other", NULL) == RES_OK, "independent transaction mount");
    const char *multiple[] = {"save", "other"};
    CHECK(h_fs_CommitList(multiple, 2) != RES_OK, "independent trees cannot partially publish"); notified(n, 0);
    CHECK(!rm_tree(root), "fixture cleanup");
    printf("save commit callback: %d checks, %d failed, %d notifications\n", checks, failures, notifications);
    return failures != 0;
}
