// Return YouTube Dislike looks for its resources under the jailbreak root with libroot. In a
// sideloaded IPA there is no jailbreak root and RYD.bundle sits in the app itself, so the path
// is returned as is (RYD checks the app bundle first anyway).
#include <limits.h>
#include <string.h>

char *libroot_dyn_jbrootpath(const char *path, char *resolvedPath) {
    if (path == NULL || resolvedPath == NULL) return NULL;
    strlcpy(resolvedPath, path, PATH_MAX);
    return resolvedPath;
}
