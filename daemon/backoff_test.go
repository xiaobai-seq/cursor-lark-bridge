package main

import (
	"testing"
	"time"
)

func TestBackoffNextSequence(t *testing.T) {
	b := newBackoff(2*time.Second, 300*time.Second)
	want := []time.Duration{
		2 * time.Second,
		4 * time.Second,
		8 * time.Second,
		16 * time.Second,
		32 * time.Second,
		64 * time.Second,
		128 * time.Second,
		256 * time.Second,
		300 * time.Second, // capped
		300 * time.Second,
		300 * time.Second,
	}
	for i, w := range want {
		got := b.Next()
		if got != w {
			t.Errorf("iter %d: want %v, got %v", i, w, got)
		}
	}
}

func TestBackoffReset(t *testing.T) {
	b := newBackoff(2*time.Second, 300*time.Second)
	for i := 0; i < 5; i++ {
		b.Next()
	}
	if b.Next() == 2*time.Second {
		t.Fatalf("预期此时远大于 2s")
	}
	b.Reset()
	if got := b.Next(); got != 2*time.Second {
		t.Errorf("Reset 后首次 Next 应为 initial=2s，实际 %v", got)
	}
}

func TestBackoffCurrentNonMutating(t *testing.T) {
	b := newBackoff(2*time.Second, 300*time.Second)
	// Next 一次 current=2s；下次 Next 会 double 到 4s
	b.Next()
	c1 := b.Current()
	c2 := b.Current()
	if c1 != c2 {
		t.Errorf("Current 应幂等，实际 c1=%v c2=%v", c1, c2)
	}
	if next := b.Next(); next != c1 {
		t.Errorf("Next 应返回 Current 预测值 %v，实际 %v", c1, next)
	}
}

func TestBackoffEdgeCases(t *testing.T) {
	// initial == max 也算合法
	b := newBackoff(5*time.Second, 5*time.Second)
	for i := 0; i < 5; i++ {
		if got := b.Next(); got != 5*time.Second {
			t.Errorf("initial==max 下应始终返回 5s，第 %d 次返回 %v", i, got)
		}
	}

	// initial <= 0 应 panic
	defer func() {
		if r := recover(); r == nil {
			t.Error("initial=0 应 panic")
		}
	}()
	_ = newBackoff(0, 5*time.Second)
}

func TestBackoffMaxLessThanInitialPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("max < initial 应 panic")
		}
	}()
	_ = newBackoff(10*time.Second, 5*time.Second)
}
