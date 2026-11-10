"""Part 1 of the ttl-cache bench case: tests written from the prompt's spec, not from any reply."""
import pytest
from ttl_cache import TTLCache


class Clock:
    def __init__(self): self.t = 0.0
    def __call__(self): return self.t


@pytest.fixture
def clock(): return Clock()


def test_capacity_must_be_positive(clock):
    with pytest.raises(ValueError): TTLCache(0, clock)
    with pytest.raises(ValueError): TTLCache(-1, clock)


def test_ttl_must_be_positive(clock):
    c = TTLCache(2, clock)
    with pytest.raises(ValueError): c.set("a", 1, ttl=0)
    with pytest.raises(ValueError): c.set("a", 1, ttl=-1)


def test_get_default_and_value(clock):
    c = TTLCache(2, clock)
    assert c.get("x") is None and c.get("x", 7) == 7
    c.set("a", 1)
    assert c.get("a") == 1


def test_lru_eviction(clock):
    c = TTLCache(2, clock)
    c.set("a", 1); c.set("b", 2)
    assert c.get("a") == 1
    c.set("c", 3)
    assert c.get("b") is None and c.get("a") == 1 and c.get("c") == 3


def test_expiry_at_the_boundary(clock):
    c = TTLCache(2, clock)
    c.set("a", 1, ttl=5)
    clock.t = 4.999
    assert c.get("a") == 1
    clock.t = 5
    assert c.get("a") is None
    assert "a" not in c and len(c) == 0


def test_expired_go_before_lru(clock):
    c = TTLCache(2, clock)
    c.set("a", 1, ttl=1); c.set("b", 2)
    assert c.get("a") == 1          # a is now most recently used, but will expire
    clock.t = 2
    c.set("c", 3)
    assert c.get("b") == 2 and c.get("c") == 3 and c.get("a") is None


def test_overwrite_replaces_value_ttl_and_recency(clock):
    c = TTLCache(2, clock)
    c.set("a", 1, ttl=1); c.set("b", 2)
    c.set("a", 10)                   # no ttl now, and most recently used
    clock.t = 100
    assert c.get("a") == 10
    c.set("c", 3)                    # b is least recently used
    assert "b" not in c and "a" in c and "c" in c


def test_contains_keeps_recency(clock):
    c = TTLCache(2, clock)
    c.set("a", 1); c.set("b", 2)
    assert "a" in c
    c.set("c", 3)
    assert "a" not in c and "b" in c and "c" in c


def test_delete(clock):
    c = TTLCache(2, clock)
    c.set("a", 1); c.set("b", 2, ttl=1)
    assert c.delete("a") is True and c.delete("a") is False and c.delete("zz") is False
    clock.t = 1
    assert c.delete("b") is False


def test_len_counts_live_entries(clock):
    c = TTLCache(3, clock)
    c.set("a", 1, ttl=1); c.set("b", 2); c.set("c", 3, ttl=10)
    assert len(c) == 3
    clock.t = 1
    assert len(c) == 2
