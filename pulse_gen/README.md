# Pulse generator for qubit control

## Context

### Qubit control

Across multiple quantum computing architectures, pulse generation is needed for qubit state preparation, single/two-qubit gate operation, and readout.

A pulse consists of a carrier wave oscillating within an envelope. The frequency of the carrier wave is set according to the architecture and the task. For example, to rotate a superconducting qubit with a specific $$\omega_{01}$$ (5-7 GHz; in the microwave range), the frequency of the carrier wave is set to same value.

The envelope determines how intensity and duration of the pulse. Intensity determines how fast the qubit state rotates through Rabi oscillation. Together with duration, they determine the actual rotation.

Due to the sharp change in the time domain at the beginning and end of a pulse, a broad range of frequency components are introduced into the pulse's spectrum. The goal of envelop shaping is to suppress unwanted frequency components, which are sources of noise.

### DRAG pulse

DRAG pulse is designed to suppress internal leakage: the target qubit state drifting outside of $$\ket{0}$$ and $$\ket{1}$$ and into $$\ket{2}$$, $$\ket{3}$$ etc. Internal leakage into $$\ket{2}$$ happens when the qubit in $$\ket{1}$$ is driven by a non-negligible frequency component close to $$\omega_{12}$$.

The DRAG (Derivative Removal by Adiabatic Gate) technique was proposed by Motzoi et. al. in 2009 in this [paper](https://arxiv.org/pdf/0901.0534). Limiting to a three-level system $$\ket{0}$$, $$\ket{1}$$ and $$\ket{2}$$, and denoting the in-phase and quadrature components to $$I(t)$$ and $$Q(t)$$ respectively, they found that setting $$Q(t) \propto \dot{I(t)}$$ can suppress leakage to $$\ket{2}$$ to the first order of the pulse amplitude. Higher-order leakage suppression is possible but we limit this exercise to first-order DRAG.

Using Gaussian as $$I(t)$$, we have:

MATH

in which $$\beta$$ is a tunable parameter.

### Wah-Wah pulse

Wah-Wah pulse is designed to suppress external leakage: the states of neighboring qubits drifting outside of $$\ket{0}$$ and $$\ket{1}$$ and into $$\ket{2}$$, $$\ket{3}$$ etc. External leakage of qubit $$j$$ in $$\ket{1}^j$$ into $$\ket{2}^j$$ happens when (1) there is a non-negligible frequency component close to $$\omega^j_{12}$$ present in the pulse targeting qubit $$i$$, and (2) qubit $$i$$ and $$j$$ are neighbors and share the same microwave line.

The Wah-Wah technique was proposed by Schutjens et. al. in 2013 in this [paper](https://arxiv.org/pdf/1306.2279). Qubits sharing the same microwave line are set to different frequencies ($$\omega_{01}$$) but this can result in one's $$\omega_{01}$$ only slightly detuned from its neighbor's $$\omega_{12}$$ (leakage transition), as shown in the following diagram extracted from the 2013 paper:

IMAGE

They found that by modulating the original $$I(t)$$ (e.g. a Gaussian envelope) with a $$[1 - A_m \cos{\omega_m (n-\mu)}]$$ term, $$\mu$$ being the same as that used in the Gaussian term, and $$Q(t)$$ follows the DRAG technique, external leakage can be suppressed.

So we have:

MATH

in which $$\beta$$, $$A_m$$, $$\omega_m$$ are tunable parameters.

## Schematics

IMAGE

TB sets the pulse parameters and trigger pulse generation by asserting `start`.

The pulse generator module generates I and Q samples in a continuous stream, asserts `busy` when generating samples, and asserts `out_last` when the last sample of the current pulse is at the output.

## Design

The following numerical methods and formats are used:

- For the Gaussian envelope, $$\exp(-x)$$ is computed with a lookup table (LUT). All arithmetic for the Gaussian datapath is performed in UQ0.15 format (unsigned, 16 bits wide, with 15 fractional bits).
- The Wah-Wah cosine term $$\cos(\omega_m (n-\mu))$$ is also produced by a LUT. The cosine datapath accepts the modulation frequency in UQ0.16 (unsigned, 16 bits, 16 fractional) and outputs in SQ1.15 format (signed, 16 bits, 1 integer + 15 fractional). The Wah-Wah modulation amplitude $$A_m$$ uses SQ0.15 format (signed, 16 bits, 15 fractional).
- The Q(t) samples of DRAG is computed with a symmetric first-order finite difference: $$D[n] = (E[n+1] - E[n-1])/2$$, where E[n] is the envelope term of the I(t) component. Forward/backward differences are used for samples at the boundaries. All envelope and difference values are kept in UQ1.15 (unsigned, 16 bits, 1 integer + 15 fractional) or a signed extension (e.g., Q2.15 for differences).

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

## Plots

IMAGE