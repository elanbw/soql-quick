#!/usr/bin/env Rscript

file_arg <- commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))][1L]
test_path <- normalizePath(sub("^--file=", "", file_arg))
backend_path <- file.path(dirname(test_path), "query_backend.R")
source_lines <- readLines(backend_path, warn = FALSE)
definitions_end <- grep("^tryCatch\\(\\{$", source_lines)[1L] - 1L
eval(parse(text = source_lines[seq_len(definitions_end)]), envir = globalenv())

assert_equal <- function(actual, expected, label) {
  if (!identical(actual, expected)) stop(label, ": expected ", deparse(expected), ", got ", deparse(actual))
}

assert_equal(cell_string(NA_character_), "", "null cell")
assert_equal(cell_string("a\tb\nc"), "a\tb\nc", "raw cell text")

one_column_json <- jsonlite::toJSON(list(
  ok = TRUE,
  columns = array_values("Account__r.Name"),
  textColumns = array_values(TRUE),
  rows = list(list("Synthetic Org"))
), auto_unbox = TRUE)
one_column_parsed <- jsonlite::fromJSON(one_column_json, simplifyVector = FALSE)
assert_equal(one_column_parsed$columns, list("Account__r.Name"), "one-column metadata stays an array")
assert_equal(one_column_parsed$textColumns, list(TRUE), "one-column type metadata stays an array")
assert_equal(one_column_parsed$rows, list(list("Synthetic Org")), "one-column rows stay nested")
cat("Backend unit tests passed.\n")
