#!/usr/bin/env python3
import json
import matplotlib.pyplot as plt

def plot_pulse(pulse, out_prefix=None):
    name = pulse["name"]
    samples = pulse["samples"]

    n = [s["n"] for s in samples]

    dut_i = [s["dut_i_r"] for s in samples]
    gold_i = [s["gold_i_r"] for s in samples]

    dut_q = [s["dut_q_r"] for s in samples]
    gold_q = [s["gold_q_r"] for s in samples]

    fig = plt.figure(figsize=(10, 6))

    ax1 = fig.add_subplot(2, 1, 1)
    ax1.plot(n, dut_i, label="DUT I")
    ax1.plot(n, gold_i, label="Golden I", linestyle="--")
    ax1.set_title(f"{name}  (len={pulse['params']['len']} mu={pulse['params']['mu']})")
    ax1.set_ylabel("I (real, SQ0.15 scaled)")
    ax1.grid(True)
    ax1.legend()

    ax2 = fig.add_subplot(2, 1, 2)
    ax2.plot(n, dut_q, label="DUT Q")
    ax2.plot(n, gold_q, label="Golden Q", linestyle="--")
    ax2.set_xlabel("Sample index n")
    ax2.set_ylabel("Q (real, SQ0.15 scaled)")
    ax2.grid(True)
    ax2.legend()

    fig.tight_layout()

    fname = f"{name}.png" if out_prefix is None else f"{out_prefix}_{name}.png"
    fig.savefig(fname, dpi=150)
    plt.close(fig)
    print(f"Wrote {fname}")

def main():
    with open("pulse_results.json", "r") as f:
        data = json.load(f)

    pulses = data["pulses"]
    if len(pulses) != 3:
        print(f"Warning: expected 3 pulses, found {len(pulses)}")

    for p in pulses:
        plot_pulse(p)

if __name__ == "__main__":
    main()

