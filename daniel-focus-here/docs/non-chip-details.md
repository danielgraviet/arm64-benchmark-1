# Details Outside Vera

The same Daytona software ran on Vera and on the other chips. Vera is still faster, so the chip is real. The headline numbers also effected by three software choices.

## Warm Snapshots (Real Customer Use-Case)

We do not build a new computer from an empty box every time a sandbox starts. We keep a saved copy of a computer that is already set up, and we wake that copy. Waking a thousand of those copies on one Vera socket takes about eleven seconds. The same wake-up on the fast high-clock chip takes the middle thirties of seconds. Lots of people already keep a warm snapshot, a saved copy of a computer that is already set up, because waking that copy makes the next startup much faster than building from an empty computer, and that is a real way customers start work. When that saved-copy path is turned off, the same jobs take longer on every chip.

## Resource Allocation (A Small Slice of the Chip)

We fill the machine the way our customer workloads run. Each sandbox gets a small slice of the chip, and we keep adding sandboxes until there are hundreds or about two thousand. We time the work only after the sandboxes are already open, so startup is not hiding inside the speed. Once the machine is full, Vera finishes about thirteen of these agent jobs each second. The high-clock chip stays near eight. The chip with more cores stays near eleven. That is the same software job, under a full house. 

## Throughput

The jobs-per-second number is the work after the sandboxes are open. We hold the fleet, then run the agent loop. At the packed peak the jobs are about 94% of that time. Creating them is about 5%. Tearing them down is about 1%.

Almost all of the job is the tests. About 92% is a heavy pytest that burns the processor. About 4% is a short pytest that is supposed to fail. About 3% is parsing the files. Writing, searching, and the patch are under 1%. Every chip ran the same image and the same seed, and the runs returned the same checksum.

As the machine fills, each job takes longer and the rate stays flat. Onsite, a job is about 6 seconds at 44 sandboxes and about 24 seconds at 352. The OCI Vera server roughly matched those numbers (accounting for the different memory).

What sits outside the chip is Daytona's sandboxing. Each sandbox is its own computer, reserved 0.025 of a processor, allowed to borrow one. The control plane assigns those jobs across the machine, at the scale of hundreds to about two thousand sandboxes. That reservation logic is what keeps a full server efficient and the chip is what does the work. The software is what makes that many isolated computers share it. 

## Operating System Details

The operating system keeps a list of where each sandbox's memory lives (page table). If memory is handed out in tiny pieces, the list gets long, and the chip spends time walking the list instead of doing the agent's work. Vera's operating system uses bigger pieces, so the list stays short. (64 KiB) That is a setting in the software around the chip. 

## Memory and Disk

They asked if memory or disk is what gets the startup to about eight times. Vera opens a thousand sandboxes in about eleven seconds. The chip with more cores takes about eighty-eight. Once the sandboxes are open, Vera finishes about thirteen jobs a second and that chip finishes about eleven.

Every sandbox got the same memory and the same disk, about 64 megabytes and 1 gigabyte. Waking the saved copy still reads the disk and pours that memory back in, so a faster disk or more room to move memory can sit in the eleven seconds. The high-clock chip does this same start in the middle thirties. When the one-processor cap was left off on that chip, the start went from about 36 seconds to 86.

> Daytona wakes saved copies, packs the machine full of small sandboxes, and keeps the memory list short.

On that path, one Vera socket opens a thousand sandboxes in about eleven seconds and then finishes about thirteen agent jobs each second. The same software is slower on the other chips. The gain is the software and the chip together.

### Technical Details

- Page size. Vera's operating system hands out memory in 64 kilobyte pieces. A usual operating system uses 4 kilobyte pieces. One big piece is 65,536 bytes. For the same small sandbox, the list of where memory lives is about sixteen times shorter. On a Vera machine, opening a thousand sandboxes took about 22 seconds with the big pieces and about 24 seconds with the small ones. That is about one tenth.
- Network connections. The test program keeps a pool of connections to the service on the same machine. The thousand-sandbox start on Vera used 1,024 connections. The two-thousand start used 4,096. The full-machine run that finished about thirteen jobs a second used 512. A pool that is too small leaves the chip waiting while the test program waits for a free connection. On Vera, with the test program on the machine, raising the pool from 100 to 600 lifted a short job from about 82 finished jobs a second to about 129. The work inside the sandbox stayed the same.
- Open files, the number 65,536. Each sandbox holds sockets and files. A normal program may only hold about 1,024 of those. Around a thousand sandboxes the run stops because it has too many files open. The startup runs raised that allowance to 65,536. The packed-job runs raise it to about a million. This is the number that looked like 665543.
- Burst cap of one processor. Each sandbox is guaranteed a small slice and may borrow up to one full processor. If that cap is left off, every sandbox is built as a 16-processor computer. On the high-clock chip, a thousand-sandbox start took 86 seconds that way, and about 36 seconds after the cap was set to one.
- The local address list, also 65,536. The operating system keeps a list of who is on the local network. The default list holds about 1,024 names. At a thousand sandboxes that list overflowed on the high-clock chip. The sandbox itself was up in about 30 milliseconds, and the software then waited on the order of 100 seconds to reach it. Raising the list to 65,536 names cut that start from 166 seconds to 86 seconds. The burst cap above took it the rest of the way to about 36 seconds.
- Where the test program sits. The numbers above were taken with the test program on the machine, talking to a service on that same machine.
- One socket. The Vera machine has two sockets. The eleven-second start places every sandbox on the first socket only, on that socket's processors and that socket's memory. The number is one socket.

