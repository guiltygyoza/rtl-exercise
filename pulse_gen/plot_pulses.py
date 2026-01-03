#!/usr/bin/env python3
import json
import matplotlib.pyplot as plt

def plot_pulse(pulse, out_prefix=None):
    name = pulse["name"]
    samples = pulse["samples"]
    params = pulse["params"]

    # Extract parameters and convert to real numbers
    len_val = params["len_uq16_0"]  # Already integer (real)
    mu_val = params["mu_uq16_0"]    # Already integer (real)
    sigma_val = params["sigma_real"]  # Already real
    amp_val = params["amp_sq0_15"] / 32768.0  # Convert SQ0.15 to real
    beta_val = params["beta_sq0_15"] / 32768.0  # Convert SQ0.15 to real
    use_ww = params["use_ww"]
    Am_val = params["Am_sq0_15"] / 32768.0  # Convert SQ0.15 to real
    wm_val = params["wm_uq0_16"] / 65536.0  # Convert UQ0.16 to real (turns per sample)

    n = [s["n"] for s in samples]

    dut_i = [s["dut_i_r"] for s in samples]
    gold_i = [s["gold_i_r"] for s in samples]

    dut_q = [s["dut_q_r"] for s in samples]
    gold_q = [s["gold_q_r"] for s in samples]

    fig = plt.figure(figsize=(10, 6))

    # I channel
    ax1 = fig.add_subplot(2, 1, 1)
    ax1.step(
        n,
        dut_i,
        where='post',
        color="black",
        linewidth=1.5,
        label="DUT I",
        zorder=1
    )
    ax1.plot(
        n,
        gold_i,
        color="orange",
        linewidth=2.0,
        label="Golden I",
        zorder=2
    )
    # Build title with conditional wah-wah parameters
    title_parts = [f"len={len_val:.0f}", f"μ={mu_val:.0f}", f"σ={sigma_val:.2f}", f"A={amp_val:.4f}", f"β={beta_val:.4f}"]
    if use_ww == 1:
        title_parts.append(f"Am={Am_val:.4f}")
        title_parts.append(f"wm={wm_val:.6f}")
    ax1.set_title(f"{name}  ({', '.join(title_parts)})")
    ax1.set_ylabel("I (real, SQ0.15 scaled)")
    ax1.grid(True)
    ax1.legend()

    # Q channel
    ax2 = fig.add_subplot(2, 1, 2)
    ax2.step(
        n,
        dut_q,
        where='post',
        color="black",
        linewidth=1.5,
        label="DUT Q",
        zorder=1
    )
    ax2.plot(
        n,
        gold_q,
        color="orange",
        linewidth=2.0,
        label="Golden Q",
        zorder=2
    )
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

    for p in pulses:
        plot_pulse(p)

if __name__ == "__main__":
    main()


# #!/usr/bin/env python3
# import json
# import matplotlib.pyplot as plt

# def plot_pulse(pulse, out_prefix=None):
#     name = pulse["name"]
#     samples = pulse["samples"]

#     n = [s["n"] for s in samples]

#     dut_i = [s["dut_i_r"] for s in samples]
#     gold_i = [s["gold_i_r"] for s in samples]

#     dut_q = [s["dut_q_r"] for s in samples]
#     gold_q = [s["gold_q_r"] for s in samples]

#     fig = plt.figure(figsize=(10, 6))

#     ax1 = fig.add_subplot(2, 1, 1)
#     ax1.plot(n, dut_i, label="DUT I")
#     ax1.plot(n, gold_i, label="Golden I", linestyle="--")
#     ax1.set_title(f"{name}  (len={pulse['params']['len']} mu={pulse['params']['mu']})")
#     ax1.set_ylabel("I (real, SQ0.15 scaled)")
#     ax1.grid(True)
#     ax1.legend()

#     ax2 = fig.add_subplot(2, 1, 2)
#     ax2.plot(n, dut_q, label="DUT Q")
#     ax2.plot(n, gold_q, label="Golden Q", linestyle="--")
#     ax2.set_xlabel("Sample index n")
#     ax2.set_ylabel("Q (real, SQ0.15 scaled)")
#     ax2.grid(True)
#     ax2.legend()

#     fig.tight_layout()

#     fname = f"{name}.png" if out_prefix is None else f"{out_prefix}_{name}.png"
#     fig.savefig(fname, dpi=150)
#     plt.close(fig)
#     print(f"Wrote {fname}")

# def main():
#     with open("pulse_results.json", "r") as f:
#         data = json.load(f)

#     pulses = data["pulses"]
#     if len(pulses) != 3:
#         print(f"Warning: expected 3 pulses, found {len(pulses)}")

#     for p in pulses:
#         plot_pulse(p)

# if __name__ == "__main__":
#     main()

