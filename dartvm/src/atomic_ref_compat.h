#pragma once
#ifdef __cplusplus
#include <atomic>

#if !defined(__cpp_lib_atomic_ref) || __cpp_lib_atomic_ref < 201806L

#include <new>
#include <type_traits>

namespace std {

template <typename T>
class atomic_ref {
    T* ptr_;

    // Load helper: read into aligned raw storage to avoid requiring
    // default constructor (e.g. dart::CompressedTypePtr is not default-
    // constructible but IS trivially copyable).
    T load_raw(memory_order order = memory_order_seq_cst) const noexcept {
        // Ensure aligned_storage doesn't zero-init
        typename aligned_storage<sizeof(T), alignof(T)>::type storage;
        __atomic_load(ptr_, reinterpret_cast<T*>(&storage), int(order));
        return reinterpret_cast<const T&>(storage);
    }

public:
    using value_type = T;
    static constexpr bool is_always_lock_free =
        __atomic_always_lock_free(sizeof(T), nullptr);
    static constexpr size_t required_alignment = alignof(T);

    explicit atomic_ref(T& obj) noexcept : ptr_(&obj) {}
    atomic_ref(const atomic_ref&) noexcept = default;
    atomic_ref& operator=(const atomic_ref&) = delete;

    T load(memory_order order = memory_order_seq_cst) const noexcept {
        return load_raw(order);
    }

    void store(T desired, memory_order order = memory_order_seq_cst) noexcept {
        __atomic_store(ptr_, &desired, int(order));
    }

    operator T() const noexcept { return load_raw(); }

    T operator=(T desired) noexcept {
        store(desired);
        return desired;
    }

    T exchange(T desired, memory_order order = memory_order_seq_cst) noexcept {
        typename aligned_storage<sizeof(T), alignof(T)>::type storage;
        __atomic_exchange(ptr_, &desired,
                          reinterpret_cast<T*>(&storage), int(order));
        return reinterpret_cast<const T&>(storage);
    }

    bool compare_exchange_weak(T& expected, T desired,
                               memory_order success,
                               memory_order failure) noexcept {
        return __atomic_compare_exchange(ptr_, &expected, &desired,
                                         true, int(success), int(failure));
    }

    bool compare_exchange_strong(T& expected, T desired,
                                 memory_order success,
                                 memory_order failure) noexcept {
        return __atomic_compare_exchange(ptr_, &expected, &desired,
                                         false, int(success), int(failure));
    }

    bool is_lock_free() const noexcept {
        return __atomic_is_lock_free(sizeof(T), ptr_);
    }

    T fetch_add(T arg, memory_order order = memory_order_seq_cst) noexcept {
        return __atomic_fetch_add(ptr_, arg, int(order));
    }

    T fetch_sub(T arg, memory_order order = memory_order_seq_cst) noexcept {
        return __atomic_fetch_sub(ptr_, arg, int(order));
    }

    T fetch_and(T arg, memory_order order = memory_order_seq_cst) noexcept {
        return __atomic_fetch_and(ptr_, arg, int(order));
    }

    T fetch_or(T arg, memory_order order = memory_order_seq_cst) noexcept {
        return __atomic_fetch_or(ptr_, arg, int(order));
    }

    T fetch_xor(T arg, memory_order order = memory_order_seq_cst) noexcept {
        return __atomic_fetch_xor(ptr_, arg, int(order));
    }
};

} // namespace std

#endif // !__cpp_lib_atomic_ref
#endif // __cplusplus
