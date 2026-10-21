// Strong front-end implementation overrides the production host's weak no-op.
void dm_test_commit_callback(const char *directory);
void dm_front_save_committed(const char *directory) { dm_test_commit_callback(directory); }
