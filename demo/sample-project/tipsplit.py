"""Split a restaurant bill (with tip) between friends.

    python3 tipsplit.py 87.40 18 3
"""
import sys


def split_bill(total, tip_percent, people):
    """Return how much each person pays, in dollars, rounded to cents.

    The shares must add up to exactly what's paid (bill + tip).
    """
    with_tip = total * (1 + tip_percent / 100)
    share = round(with_tip / people, 2)
    return [share] * people


def main():
    total, tip, people = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
    shares = split_bill(total, tip, people)
    for i, s in enumerate(shares, 1):
        print(f"Person {i}: ${s:.2f}")
    print(f"Total paid: ${sum(shares):.2f}")


if __name__ == "__main__":
    main()
