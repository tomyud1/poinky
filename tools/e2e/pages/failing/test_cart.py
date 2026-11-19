from cart import total

def test_no_discount():
    assert total([10, 20]) == 30

def test_ten_percent():
    assert total([50, 50], discount=10) == 90

def test_half_off():
    assert total([40], discount=50) == 20
