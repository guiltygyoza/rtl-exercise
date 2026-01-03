# Pulse generator for qubit control

## Context

### Qubit control

Across multiple quantum computing architectures, pulse generation is needed for qubit state preparation, single/two-qubit gate operation, and readout.

A pulse consists of a carrier wave oscillating within an envelope. The frequency of the carrier wave is set according to the architecture and the task. For example, to rotate a superconducting qubit with a specific $$\omega_{01}$$ (5-7 GHz; in the microwave range), the frequency of the carrier wave is set to same value.

The envelope determines how intensity and duration of the pulse. Intensity determines how fast the qubit state rotates through Rabi oscillation. Together with duration, they determine the actual rotation.

Due to the sharp change in the time domain at the beginning and end of a pulse, a broad range of frequency components are introduced into the pulse's spectrum. The goal of envelop shaping is to suppress unwanted frequency components, which are sources of noise.

### DRAG pulse

DRAG pulse is designed to suppress internal leakage: the target qubit state drifting outside of $$\ket{0}$$ and $$\ket{1}$$ and into $$\ket{2}$$, $$\ket{3}$$ etc. Internal leakage into $$\ket{2}$$ happens when the qubit in $$\ket{1}$$ is driven by a non-negligible frequency component close to $$\omega_{12}$$.

The DRAG (Derivative Removal by Adiabatic Gate) technique was proposed by Motzoi et. al. in 2009 in this [paper](https://arxiv.org/pdf/0901.0534). Limiting to a three-level system $$\ket{0}$$, $$\ket{1}$$ and $$\ket{2}$$, and denoting the in-phase and quadrature components to $$I(t)$$ and $$Q(t)$$ respectively, they found that setting $$Q(t) \propto \frac{dI(t)}{dt}$$ can suppress leakage to $$\ket{2}$$ to the first order of the pulse amplitude. Higher-order leakage suppression is possible but we limit this exercise to first-order DRAG.

Using Gaussian as $$I(t)$$, we have:

```math
\begin{align*}
I[n] = A \cdot G[n] \\
Q[n] = \beta \cdot A \cdot D[n] \\
\end{align*}
```

where:

```math
\begin{align*}
G[n] = \exp\left(-\frac{(n-\mu)^2}{2\sigma^2}\right) \\
D[n] =
\begin{cases}
	G[n+1] - G[n] & n = 0 \\
	G[n] - G[n-1] & n = L-1 \\
	\frac{G[n+1] - G[n-1]}{2} & \text{otherwise}
\end{cases}
\end{align*}
```

in which $$\beta$$ is a tunable parameter for DRAG.

### Wah-Wah pulse

Wah-Wah pulse is designed to suppress external leakage: the states of neighboring qubits drifting outside of $$\ket{0}$$ and $$\ket{1}$$ and into $$\ket{2}$$, $$\ket{3}$$ etc. External leakage of qubit $$j$$ in $$\ket{1}^j$$ into $$\ket{2}^j$$ happens when (1) there is a non-negligible frequency component close to $$\omega^j_{12}$$ present in the pulse targeting qubit $$i$$, and (2) qubit $$i$$ and $$j$$ are neighbors and share the same microwave line.

The Wah-Wah technique was proposed by Schutjens et. al. in 2013 in this [paper](https://arxiv.org/pdf/1306.2279). Qubits sharing the same microwave line are set to different frequencies ($$\omega_{01}$$) but this can result in one's $$\omega_{01}$$ only slightly detuned from its neighbor's $$\omega_{12}$$ (leakage transition), as shown in the following diagram extracted from the 2013 paper:

<p align="center">
  <img width="691" height="562" alt="image" src="https://github.com/user-attachments/assets/f0db91c7-d4a7-4ff5-a8d7-0eef4e1bd8ea" />
</p>

They found that by modulating the original $$I(t)$$ (e.g. a Gaussian envelope) with a $$[1 - A_m \cos{\omega_m (n-\mu)}]$$ term, $$\mu$$ being the same as that used in the Gaussian term, and $$Q(t)$$ follows the DRAG technique, external leakage can be suppressed.

So we have:

```math
\begin{align*}
I[n] = A \cdot E[n] \\
Q[n] = \beta \cdot A \cdot D[n] \\
\end{align*}
```

where:

```math
\begin{align*}
E[n] = G[n] \left[1 - A_m \cos\left(\omega_m (n-\mu)\right)\right] \\
D[n] =
  \begin{cases}
    E[n+1] - E[n] & n = 0 \\
    E[n] - E[n-1] & n = L-1 \\
    \frac{E[n+1] - E[n-1]}{2} & \text{otherwise}
  \end{cases} \\
\end{align*}
```

in which $$\beta$$, $$A_m$$, $$\omega_m$$ are tunable parameters for Wah-Wah.

## Schematics

<img width="985" height="442" alt="image" src="https://github.com/user-attachments/assets/e948aac1-e791-4952-a1a7-37f3857e8993" />

TB sets the pulse parameters and trigger pulse generation by asserting `start`.

The pulse generator module generates I and Q samples in a continuous stream, asserts `busy` when generating samples, and asserts `out_last` when the last sample of the current pulse is at the output.

The pulse generator would refuse to generate samples if the pulse parameters are erroneous: pulse sample length must be at least 2, `mu` (Gaussian mean) must not be smaller than the sample length, the sigma square inverse term must not be zero, and Wah-Wah frequency term must not be zero when Wah-Wah is turned on.

TB collects the generated samples and checks them against golden values (calculated using SystemVerilog's system functions `$exp()` and `$cos()`). TB also checks if DUT refuses to generate under erroneous pulse parameters.

Finally, TB exports all DUT-agenerated samples into a single JSON file. A script `plot_pulses.py` visualizes those samples.

## Design

The following numerical methods and formats are used:

- For the Gaussian envelope, $$\exp(-x)$$ is computed with a lookup table (LUT) with 11-bit address. All arithmetic for the Gaussian datapath is performed in UQ0.15 format (unsigned, 16 bits wide, with 15 fractional bits).
- The Wah-Wah cosine term $$\cos(\omega_m (n-\mu))$$ is also produced by a LUT with 11-bit address. The cosine datapath accepts the modulation frequency in UQ0.16 (unsigned, 16 bits, 16 fractional) and outputs in SQ1.15 format (signed, 16 bits, 1 integer + 15 fractional). The Wah-Wah modulation amplitude $$A_m$$ uses SQ0.15 format (signed, 16 bits, 15 fractional).
- The Q(t) samples of DRAG is computed with a symmetric first-order finite difference: $$D[n] = (E[n+1] - E[n-1])/2$$, where E[n] is the envelope term of the I(t) component. Forward/backward differences are used for samples at the boundaries. All envelope and difference values are kept in UQ1.15 (unsigned, 16 bits, 1 integer + 15 fractional) or a signed extension (e.g., Q2.15 for differences).
- All LUT outputs are interpolated linearly between adjacent address entries to improve accuracy at the input's fractional address.

## CLI commands

To compile SystemVerilog sources into an executable; the resulting executable `tb_sim` can be found under the generated folder `obj_dir` :

```bash
verilator -Wall --sv --trace --binary tb_pulse_gen.sv pulse_gen.sv gaussian_datapath.sv cosine_datapath.sv exp_lut_2048.sv cos_lut_2048.sv --top-module tb_pulse_gen -o tb_sim
```

To run the executable, generate the json that contains pulse samples, and dump the waveform:

```bash
./obj_dir/tb_sim +VCD
```

To view the waveform:

```bash
GTKWave tb_pulse_gen.vcd
```

To generate the plots from pulse samples:
```bash
python plot_pulses.py
```

CLI message indicating test passing:

```bash
> ./obj_dir/tb_sim +VCD
PASS: Pulse len=1024 mu=512 inv_sig2=0x00038e39 amp=16384 beta=0 use_ww=0 Am=0 wm=0 protocol+math=1, all in-phase values within 1 LSB(s) and quadrature values within 2 LSB(s) from golden.
PASS: Pulse len=900 mu=450 inv_sig2=0x0006332a amp=-8192 beta=19661 use_ww=0 Am=0 wm=0 protocol+math=1, all in-phase values within 1 LSB(s) and quadrature values within 2 LSB(s) from golden.
PASS: Pulse len=480 mu=240 inv_sig2=0x0008ff39 amp=24576 beta=6144 use_ww=0 Am=0 wm=0 protocol+math=1, all in-phase values within 1 LSB(s) and quadrature values within 2 LSB(s) from golden.
PASS: Pulse len=512 mu=256 inv_sig2=0x00051eb9 amp=20480 beta=8192 use_ww=1 Am=29491 wm=128 protocol+math=1, all in-phase values within 1 LSB(s) and quadrature values within 2 LSB(s) from golden.
PASS: Invalid cmd rejected. len=32 mu=32 inv_sig2=0x08000001 use_ww=0 wm=0
PASS: Invalid cmd rejected. len=2 mu=0 inv_sig2=0x20000001 use_ww=0 wm=0
PASS: Invalid cmd rejected. len=16 mu=8 inv_sig2=0x00000000 use_ww=0 wm=0
PASS: Invalid cmd rejected. len=64 mu=32 inv_sig2=0x0147ae15 use_ww=1 wm=0
PASS: All tests completed (protocol + invalid + DRAG math).
- tb_pulse_gen.sv:758: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.042 2025-11-02
- Verilator: $finish at 32us; walltime 0.043 s; speed 857.274 us/s
- Verilator: cpu 0.037 s on 1 threads; alloced 0 MB
```

TB validates all I samples are within 1 LSB error tolerance, and all Q samples are within 2 LSB error tolerance.

## Plots

DRAG pulse 0:
<img width="1500" height="900" alt="image" src="https://github.com/user-attachments/assets/ffeb998a-4e54-4c34-82eb-d7d9981eac74" />

DRAG pulse 1:
<img width="1500" height="900" alt="image" src="https://github.com/user-attachments/assets/74329699-ba74-4115-895a-ba74fc5206dc" />

DRAG pulse 2:
<img width="1500" height="900" alt="image" src="https://github.com/user-attachments/assets/4a2a0dcc-6919-484f-9577-38aa8816f866" />

Wah-Wah pulse:
<img width="1500" height="900" alt="image" src="https://github.com/user-attachments/assets/7c632379-ff27-4d88-9fc1-b47d941c4816" />
