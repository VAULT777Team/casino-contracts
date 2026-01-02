SECONDS_PER_YEAR = 31_536_000
WEI_PER_ETH = 10**18


def parse_percent(s: str) -> float:
	s = s.strip()
	if s.endswith("%"):  # allow "8%"
		s = s[:-1].strip()
	return float(s) / 100.0


def main() -> None:
	tvl_eth = float(input("expected ETH TVL: ").strip())
	apy = parse_percent(input("APY (e.g. 8 or 8%): "))

	tvl_wei = int(tvl_eth * WEI_PER_ETH)
	annual_rewards_wei = int(tvl_wei * apy)
	reward_rate_wei_per_sec = annual_rewards_wei // SECONDS_PER_YEAR

	print("tvl_wei:", tvl_wei)
	print("annual_rewards_wei:", annual_rewards_wei)
	print("rewardRate (wei/sec):", reward_rate_wei_per_sec)
	print("addPool(address(0),", reward_rate_wei_per_sec, ")")


if __name__ == "__main__":
	main()
