def total(prices, discount=0):
    """Sum the prices and take off a percentage discount (10 means 10%)."""
    subtotal = sum(prices)
    return subtotal - discount
