/****************************************************************************/
/*                           the diy toolsuite                              */
/*                                                                          */
/* Jade Alglave, University College London, UK.                             */
/* Luc Maranget, INRIA Paris-Rocquencourt, France.                          */
/*                                                                          */
/* Copyright 2013-present Institut National de Recherche en Informatique et */
/* en Automatique and the authors. All rights reserved.                     */
/*                                                                          */
/* This software is governed by the CeCILL-B license under French law and   */
/* abiding by the rules of distribution of free software. You can use,      */
/* modify and/ or redistribute the software under the terms of the CeCILL-B */
/* license as circulated by CEA, CNRS and INRIA at the following URL        */
/* "http://www.cecill.info". We also give a copy in LICENSE.txt.            */
/****************************************************************************/

/* HetLitmus: the per-iteration slot layout every compound harness addresses.
 *
 * Each shared location is allocated SIZE_OF_TEST slots, and iteration n of the
 * persistent loop touches slot n ALONE: the outcome of iteration n is then read
 * back from slot n, with no search and no decoding.  Both sides address the
 * same slot -- the GPU lane inside the kernel, the CPU thread through the
 * address its caller passes it -- so the pairing is a property of the
 * addressing, not of a reconstruction afterwards.
 *
 * This header travels to GPU boxes inside a harness directory, so it stands on
 * its own.  Design: hetlitmus/docs/00-environment-design.md. */

#ifndef HET_RDV_H
#define HET_RDV_H

/* Distance between one iteration's slot and the next, in elements of the shared
   arrays (int).  16 ints = 64 B, so two iterations never share a word, and the
   memory a location costs is SIZE_OF_TEST * 64 B. */
#ifndef HET_SLOT_STRIDE_WORDS
#define HET_SLOT_STRIDE_WORDS 16
#endif

#endif /* HET_RDV_H */
