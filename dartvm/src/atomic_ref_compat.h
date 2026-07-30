#pragma once
#include <atomic>

#if !defined(__cpp_lib_atomic_ref) || __cpp_lib_atomic_ref < 201806L

namespace std {

template <typename T>
class atomic_ref {
    T* ptr_;

public:
    using value_type = T;
    static constexpr bool is_always_lock_free =
        __atomic_always_lock_free(sizeof(T), nullptr);
    static constexpr size_t required_alignment = alignof(T);

    explicit atomic_ref(T& obj) noexcept : ptr_(&obj) {}
    atomic_ref(const atomic_ref&) noexcept = default;
    atomic_ref& operator=(const atomic_ref&) = delete;

    T load(memory_order order = memory_order_seq_cst) const noexcept {
        T tmp;
        __atomic_load(ptr_, &tmp, int(order));
        return tmp;
    }

    void store(T desired, memory_order order = memory_order_seq_cst) noexcept {
        __atomic_store(ptr_, &desired, int(order));
    }

    T exchange(T desired, memory_order order = memory_order_seq_cst) noexcept {
        T tmp;
        __atomic_exchange(ptr_, &desired, &tmp, int(order));
        return tmp;
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

    T operator=(T desired) noexcept {
        store(desired);
        return desired;
    }

    operator T() const noexcept { return load(); }

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
