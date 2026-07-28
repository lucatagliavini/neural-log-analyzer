#!/bin/bash
#
# vocab.sh — loader del vocabolario NLP per il profilo "liquido".
# Legge unigrams.txt e bigrams.txt e popola gli array UNIGRAMS, BIGRAMS
# e la variabile NUM_FEATURES usati da query-to-features.sh e build-dataset.sh.
#
# Per modificare il vocabolario: editare unigrams.txt o bigrams.txt.
# Non modificare questo file salvo cambiamenti strutturali al formato.
#

_VOCAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t UNIGRAMS < <(grep -v '^[[:space:]]*#' "$_VOCAB_DIR/unigrams.txt" | grep -v '^[[:space:]]*$')
mapfile -t BIGRAMS  < <(grep -v '^[[:space:]]*#' "$_VOCAB_DIR/bigrams.txt"  | grep -v '^[[:space:]]*$')

NUM_FEATURES=$(( ${#UNIGRAMS[@]} + ${#BIGRAMS[@]} ))
