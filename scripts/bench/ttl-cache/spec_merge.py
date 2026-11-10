"""Part 2 of the ttl-cache bench case: tests written from the prompt's spec."""
import pytest
from merge import merge_intervals


def test_empty(): assert merge_intervals([]) == []
def test_touching(): assert merge_intervals([(1, 3), (3, 5)]) == [(1, 5)]
def test_overlap(): assert merge_intervals([(1, 4), (2, 6), (8, 9)]) == [(1, 6), (8, 9)]
def test_contained(): assert merge_intervals([(1, 10), (2, 3)]) == [(1, 10)]
def test_unsorted(): assert merge_intervals([(5, 6), (1, 2)]) == [(1, 2), (5, 6)]
def test_input_untouched():
    data = [(5, 6), (1, 2)]
    merge_intervals(data)
    assert data == [(5, 6), (1, 2)]
def test_invalid():
    with pytest.raises(ValueError): merge_intervals([(3, 1)])
def test_returns_tuples(): assert all(isinstance(i, tuple) for i in merge_intervals([(1, 2), (2, 3)]))
