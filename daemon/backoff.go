package main

import "time"

// backoffState 实现 2s → 4s → 8s → ... → max 的指数退避。
// 不是 goroutine 安全，调用方若并发使用请自行加锁。
type backoffState struct {
	initial time.Duration
	max     time.Duration
	current time.Duration
}

// newBackoff 构造一个 backoff，首次 Next() 返回 initial。
// initial/max 非正时 panic（防呆）。
func newBackoff(initial, max time.Duration) *backoffState {
	if initial <= 0 || max < initial {
		panic("backoff: initial must be positive and max >= initial")
	}
	return &backoffState{initial: initial, max: max}
}

// Next 返回下一次应该等的时长，并把内部状态 double。
// 首次调用返回 initial；达到 max 后持续返回 max。
func (b *backoffState) Next() time.Duration {
	if b.current == 0 {
		b.current = b.initial
		return b.current
	}
	next := b.current * 2
	if next > b.max {
		next = b.max
	}
	b.current = next
	return b.current
}

// Reset 把状态恢复到初始（下次 Next 返回 initial）。
func (b *backoffState) Reset() {
	b.current = 0
}

// Current 返回"如果现在调 Next 会返回的值"，不改变状态。
// 仅供日志 / 观测用，业务逻辑应该用 Next。
func (b *backoffState) Current() time.Duration {
	if b.current == 0 {
		return b.initial
	}
	next := b.current * 2
	if next > b.max {
		return b.max
	}
	return next
}
