import unittest
from tipsplit import split_bill


class SplitBillTest(unittest.TestCase):
    def test_even_split(self):
        self.assertEqual(split_bill(100, 20, 4), [30.0, 30.0, 30.0, 30.0])

    def test_shares_add_up_to_the_total(self):
        # $10 + 0% tip between 3 people: someone has to pay the extra cent.
        shares = split_bill(10, 0, 3)
        self.assertAlmostEqual(sum(shares), 10.00, places=2)

    def test_uneven_with_tip(self):
        shares = split_bill(87.40, 18, 3)
        self.assertAlmostEqual(sum(shares), round(87.40 * 1.18, 2), places=2)
        self.assertLessEqual(round(max(shares) - min(shares), 2), 0.01)


if __name__ == "__main__":
    unittest.main()
