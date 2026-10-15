/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260930 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of SSDT7.dat
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x00002DBE (11710)
 *     Revision         0x02
 *     Checksum         0xA3
 *     OEM ID           "NVIDIA"
 *     OEM Table ID     "BPMPTLMT"
 *     OEM Revision     0x00000001 (1)
 *     Compiler ID      "DYNT"
 *     Compiler Version 0x00010000 (65536)
 */
DefinitionBlock ("", "SSDT", 2, "NVIDIA", "BPMPTLMT", 0x00000001)
{
    External (_SB_.BPLG, IntObj)
    External (_SB_.BPLS, UnknownObj)

    Scope (_SB)
    {
        Device (BPM1)
        {
            Name (_HID, EisaId ("PNP0C02") /* PNP Motherboard Resources */)  // _HID: Hardware ID
            Name (_UID, "BPMP IPC Socket 1")  // _UID: Unique ID
            Name (TXMB, 0x000008008D600000)
            Name (RXMB, 0x000008008D601000)
            Name (DRBA, 0x0000FE54032B3000)
            OperationRegion (BPTX, SystemMemory, TXMB, 0x1000)
            Field (BPTX, AnyAcc, NoLock, Preserve)
            {
                TWCT,   32, 
                TSTA,   32, 
                Offset (0x40), 
                TRCT,   32, 
                Offset (0x80), 
                TMRQ,   32, 
                TFLA,   32, 
                TDAT,   31680
            }

            OperationRegion (BPRX, SystemMemory, RXMB, 0x1000)
            Field (BPRX, AnyAcc, NoLock, Preserve)
            {
                RWCT,   32, 
                RSTA,   32, 
                Offset (0x40), 
                RRCT,   32, 
                Offset (0x80), 
                RERR,   32, 
                RFLG,   32, 
                RDAT,   31680
            }

            OperationRegion (DRBL, SystemMemory, DRBA, 0x0100)
            Field (DRBL, AnyAcc, NoLock, Preserve)
            {
                TRIG,   32, 
                ENA,    32, 
                RAW,    32, 
                PEND,   32
            }

            Method (BIPC, 2, Serialized)
            {
                If (((((TSTA != 0x00) || (RSTA != 0x00)) || 
                    (RWCT != RRCT)) || (TWCT != TRCT)))
                {
                    TSTA = 0x01
                    TRIG = One
                    Local0 = 0x00
                    While (((TSTA != 0x00) || (RSTA != 0x00)))
                    {
                        If ((Local0 == 0x000186A0))
                        {
                            RERR = 0x01
                            Return (Package (0x02)
                            {
                                RERR, , 
                                RDAT, 
                            })
                        }

                        If ((RSTA == 0x01))
                        {
                            TWCT = 0x00
                            RRCT = 0x00
                            TSTA = 0x02
                            TRIG = One
                        }
                        ElseIf ((TSTA == 0x02))
                        {
                            TSTA = 0x00
                            TRIG = One
                        }
                        ElseIf (((TSTA == 0x01) && (RSTA == 0x02)))
                        {
                            TWCT = 0x00
                            RRCT = 0x00
                            TSTA = 0x00
                            TRIG = One
                        }

                        Local0++
                        Stall (0x01)
                    }
                }

                TMRQ = Arg0
                TFLA = One
                TDAT = Arg1
                TWCT++
                TRIG = One
                Local0 = 0x00
                While ((RWCT == RRCT))
                {
                    If ((Local0 == 0x000186A0))
                    {
                        RERR = 0x01
                        Return (Package (0x02)
                        {
                            RERR, , 
                            RDAT, 
                        })
                    }

                    Stall (0x01)
                    Local0++
                }

                RRCT++
                Return (Package (0x02)
                {
                    RERR, , 
                    RDAT, 
                })
            }

            Name (TBUF, 0x000008008D602000)
            Name (TSIZ, 0x0C00)
            OperationRegion (TELE, SystemMemory, TBUF, 0x1000)
            Field (TELE, DWordAcc, NoLock, Preserve)
            {
                SMP0,   32
            }

            Field (TELE, DWordAcc, NoLock, Preserve)
            {
                TBFB,   32768
            }

            OperationRegion (SCPR, SystemMemory, ((TBUF + TSIZ) - 0x04), 0x04)
            Field (SCPR, DWordAcc, NoLock, Preserve)
            {
                SCPY,   32
            }

            Method (RDBF, 1, Serialized)
            {
                Local0 = 0x00
                Local6 = 0x00
                Local7 = 0x00
                Local2 = (Arg0 & 0x80000000)
                If (Local2)
                {
                    Local3 = (Arg0 & 0x7FFFFFFF)
                }
                Else
                {
                    Local3 = Arg0
                }

                Local1 = (Local3 * 0x04)
                If (Local2)
                {
                    If (((Local1 + 0x08) > TSIZ))
                    {
                        Return (0xFFFFFFFFFFFFFFFF)
                    }
                }
                ElseIf (((Local1 + 0x04) > TSIZ))
                {
                    Return (0xFFFFFFFFFFFFFFFF)
                }

                While ((Local0 < 0x64))
                {
                    Local6 = SMP0 /* \_SB_.BPM1.SMP0 */
                    Local7 = SCPY /* \_SB_.BPM1.SCPY */
                    If ((Local7 != Local6))
                    {
                        Local0++
                        Continue
                    }

                    If (Local2)
                    {
                        Local4 = ToInteger (Mid (TBFB, Local1, 0x04))
                        Local5 = ToInteger (Mid (TBFB, (Local1 + 0x04), 0x04))
                        Local4 |= (Local5 << 0x20)
                    }
                    Else
                    {
                        Local4 = ToInteger (Mid (TBFB, Local1, 0x04))
                    }

                    Local7 = SMP0 /* \_SB_.BPM1.SMP0 */
                    If ((Local7 != Local6))
                    {
                        Local0++
                        Continue
                    }

                    Return (Local4)
                }

                Return (0xFFFFFFFFFFFFFFFF)
            }

            Method (TEMP, 1, Serialized)
            {
                Local2 = RDBF (Arg0)
                Local3 = (Local2 / 0x64)
                Local4 = (Local3 + 0x0AAC)
                Return (Local4)
            }

            Method (POWR, 1, Serialized)
            {
                Return (RDBF (Arg0))
            }

            ThermalZone (TZ00)
            {
                Name (_STR, Unicode ("Thermal Zone Compute TJMax Socket 1"))  // _STR: Description String
                Name (_UID, Unicode ("Socket1-Zone144"))  // _UID: Unique ID
                Method (_TMP, 0, NotSerialized)  // _TMP: Temperature
                {
                    Return (TEMP (0x90))
                }

                Name (_TZP, 0x0A)  // _TZP: Thermal Zone Polling
                Name (_CRT, 0x0EBC)  // _CRT: Critical Temperature
            }

            ThermalZone (TZ01)
            {
                Name (_STR, Unicode ("Thermal Zone Compute TJAvg Socket 1"))  // _STR: Description String
                Name (_UID, Unicode ("Socket1-Zone146"))  // _UID: Unique ID
                Method (_TMP, 0, NotSerialized)  // _TMP: Temperature
                {
                    Return (TEMP (0x92))
                }

                Name (_TZP, 0x0A)  // _TZP: Thermal Zone Polling
                Name (_CRT, 0x0EBC)  // _CRT: Critical Temperature
            }

            ThermalZone (TZ02)
            {
                Name (_STR, Unicode ("Thermal Zone DRAM TJMax Socket 1"))  // _STR: Description String
                Name (_UID, Unicode ("Socket1-Zone192"))  // _UID: Unique ID
                Method (_TMP, 0, NotSerialized)  // _TMP: Temperature
                {
                    Return (TEMP (0xC0))
                }

                Name (_TZP, 0x0A)  // _TZP: Thermal Zone Polling
                Name (_CRT, 0x0EBC)  // _CRT: Critical Temperature
            }

            Device (PM00)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x68)
                Name (PW1S, 0x70)
                Name (SKID, One)
                Name (LIID, One)
                Name (HLIM, One)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, 0x0D)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x03E8)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "Total Power in uW socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM00.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM00, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM00, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM00, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power0")  // _UID: Unique ID
                Name (_STR, Unicode ("Total Power in uW socket 1"))  // _STR: Description String
            }

            Device (PM01)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x69)
                Name (PW1S, 0x71)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x03E8)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "AP Power in uW socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM01.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM01, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM01, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM01, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power1")  // _UID: Unique ID
                Name (_STR, Unicode ("AP Power in uW socket 1"))  // _STR: Description String
            }

            Device (PM02)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x6A)
                Name (PW1S, 0x72)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x03E8)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "CPU Rail Power in uW socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM02.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM02, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM02, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM02, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power2")  // _UID: Unique ID
                Name (_STR, Unicode ("CPU Rail Power in uW socket 1"))  // _STR: Description String
            }

            Device (PM03)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x6B)
                Name (PW1S, 0x73)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x03E8)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "SOC Rail Power in uW socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM03.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM03, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM03, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM03, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power3")  // _UID: Unique ID
                Name (_STR, Unicode ("SOC Rail Power in uW socket 1"))  // _STR: Description String
            }

            Device (PM04)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x6C)
                Name (PW1S, 0x74)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x03E8)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "DRAM Power in uW socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM04.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM04, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM04, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM04, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power4")  // _UID: Unique ID
                Name (_STR, Unicode ("DRAM Power in uW socket 1"))  // _STR: Description String
            }

            Device (PM05)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0xC8)
                Name (PW1S, 0xC8)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x32)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "CPUVDD Vtg Regulator Temperature in uC socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM05.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM05, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM05, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM05, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power5")  // _UID: Unique ID
                Name (_STR, Unicode ("CPUVDD Vtg Regulator Temperature in uC socket 1"))  // _STR: Description String
            }

            Device (PM06)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0xC9)
                Name (PW1S, 0xC9)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x32)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "SOCVDD Vtg Regulator Temperature in uC socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM06.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM06, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM06, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM06, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power6")  // _UID: Unique ID
                Name (_STR, Unicode ("SOCVDD Vtg Regulator Temperature in uC socket 1"))  // _STR: Description String
            }

            Device (PM07)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0xF8)
                Name (PW1S, 0xF9)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x03E8)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "CPU Rail Output Power in uW socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM07.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM07, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM07, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM07, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power7")  // _UID: Unique ID
                Name (_STR, Unicode ("CPU Rail Output Power in uW socket 1"))  // _STR: Description String
            }

            Device (PM08)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x0238)
                Name (PW1S, 0x0238)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x32)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "Chipthrot TCPc Throttle (samples x1000) socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM08.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM08, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM08, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM08, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power8")  // _UID: Unique ID
                Name (_STR, Unicode ("Chipthrot TCPc Throttle (samples x1000) socket 1"))  // _STR: Description String
            }

            Device (PM09)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x023B)
                Name (PW1S, 0x023B)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x32)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "Chipthrot TJMAX Throttle (samples x1000) socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM09.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM09, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM09, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM09, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power9")  // _UID: Unique ID
                Name (_STR, Unicode ("Chipthrot TJMAX Throttle (samples x1000) socket 1"))  // _STR: Description String
            }

            Device (PM0A)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x023C)
                Name (PW1S, 0x023C)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x32)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "Chipthrot TJAVG Throttle (samples x1000) socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM0A.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM0A, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM0A, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM0A, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power10")  // _UID: Unique ID
                Name (_STR, Unicode ("Chipthrot TJAVG Throttle (samples x1000) socket 1"))  // _STR: Description String
            }

            Device (PM0B)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x0241)
                Name (PW1S, 0x0241)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x32)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "Chipthrot DDR Throttle (samples x1000) socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM0B.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM0B, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM0B, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM0B, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power11")  // _UID: Unique ID
                Name (_STR, Unicode ("Chipthrot DDR Throttle (samples x1000) socket 1"))  // _STR: Description String
            }

            Device (PM0C)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x80000078)
                Name (PW1S, 0x80000078)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x32)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "Total CPU Energy In uJ socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM0C.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM0C, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM0C, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM0C, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power12")  // _UID: Unique ID
                Name (_STR, Unicode ("Total CPU Energy In uJ socket 1"))  // _STR: Description String
            }

            Device (PM0D)
            {
                Name (_HID, "ACPI000D" /* Power Meter Device */)  // _HID: Hardware ID
                Name (PWRI, 0x8000007A)
                Name (PW1S, 0x8000007A)
                Name (SKID, One)
                Name (LIID, Zero)
                Name (HLIM, Zero)
                Name (HWLT, 0xFFFFFFFF)
                Name (HINI, 0x00)
                Name (CAPS, One)
                Name (MTYP, One)
                Name (ACCU, 0x000186A0)
                Name (STIM, 0x32)
                Name (MINA, 0x32)
                Name (MAXA, 0x32)
                Name (HYST, 0xFFFFFFFF)
                Name (MINP, Zero)
                Name (MAXP, 0xFFFFFFFF)
                Name (MODL, "")
                Name (SERN, "")
                Name (OEMI, "Total Energy In uJ socket 1")
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Method (_PMC, 0, NotSerialized)  // _PMC: Power Meter Capabilities
                {
                    Return (Package (0x0E)
                    {
                        CAPS, , 
                        0x00, 
                        MTYP, , 
                        ACCU, , 
                        STIM, , 
                        MINA, , 
                        MAXA, , 
                        HYST, , 
                        0xFFFFFFFF, 
                        MINP, , 
                        MAXP, , 
                        MODL, , 
                        SERN, , 
                        OEMI, 
                    })
                }

                Method (_PMM, 0, Serialized)  // _PMM: Power Meter Measurement
                {
                    If ((STIM == 0x03E8))
                    {
                        Return (POWR (PW1S))
                    }

                    Return (POWR (PWRI))
                }

                Method (_GAI, 0, NotSerialized)  // _GAI: Get Averaging Interval
                {
                    Return (STIM) /* \_SB_.BPM1.PM0D.STIM */
                }

                Method (_PAI, 1, Serialized)  // _PAI: Power Averaging Interval
                {
                    If (((Arg0 < MINA) || (Arg0 > MAXA)))
                    {
                        Return (0x01)
                    }

                    If ((Arg0 > 0x020D))
                    {
                        Local0 = 0x03E8
                        Local1 = 0x32
                    }
                    Else
                    {
                        Local0 = 0x32
                        Local1 = 0x03E8
                    }

                    If (((Local0 >= MINA) && (Local0 <= MAXA)))
                    {
                        STIM = Local0
                    }
                    ElseIf (((Local1 >= MINA) && (Local1 <= MAXA)))
                    {
                        STIM = Local1
                    }
                    Else
                    {
                        Return (0x01)
                    }

                    Notify (PM0D, 0x84) // Reserved
                    Return (0x00)
                }

                Method (_PMD, 0, NotSerialized)  // _PMD: Power Metered Devices
                {
                    Return (Package (0x00){})
                }

                Method (_GHL, 0, Serialized)  // _GHL: Get Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    Return (\_SB.BPLG) /* External reference */
                    SKID
                    LIID
                }

                Method (_SHL, 1, Serialized)  // _SHL: Set Hardware Limit
                {
                    If ((HLIM == 0x00))
                    {
                        Return (0xFFFFFFFF)
                    }

                    If (((Arg0 < MINP) || (Arg0 > MAXP)))
                    {
                        Return (0x01)
                    }

                    Arg0 = \_SB.BPLS (SKID, LIID)
                    Local0
                    If ((Local0 == 0x00))
                    {
                        If (((HINI == 0x00) || (Arg0 != HWLT)))
                        {
                            HWLT = Arg0
                            HINI = 0x01
                            If ((CAPS & 0x08))
                            {
                                Notify (PM0D, 0x82) // Device-Specific Change
                            }
                        }

                        If ((CAPS & 0x08))
                        {
                            Notify (PM0D, 0x83) // Device-Specific Change
                        }
                    }

                    Return (Local0)
                }

                Name (_UID, "Socket1-Power13")  // _UID: Unique ID
                Name (_STR, Unicode ("Total Energy In uJ socket 1"))  // _STR: Description String
            }
        }
    }
}

