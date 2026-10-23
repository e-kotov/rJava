// Built with MSVC (dynamic CRT). Since VS 2022 17.10 std::mutex has a
// constexpr constructor; locking it with msvcp140.dll older than 14.40
// is a documented access violation. Returns _MSC_FULL_VER on success.
#include <mutex>
static std::mutex m;
extern "C" __declspec(dllexport) void mutex_probe(int *out) {
    std::lock_guard<std::mutex> guard(m);
    *out = _MSC_VER;
}
