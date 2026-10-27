#!/usr/bin/env Rscript

source(file.path(dirname(normalizePath(sub("^--file=", "", commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))][1L]))), "backend_common.R"))

json_array_shape <- function(payload, key) {
  parsed <- jsonlite::fromJSON(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"), simplifyVector = FALSE)
  is.list(parsed[[key]])
}

stopifnot(json_array_shape(list(ok = TRUE, objects = list()), "objects"))
stopifnot(json_array_shape(list(ok = TRUE, objects = list(list(apiName = "Account", label = "Account", custom = FALSE, queryable = TRUE))), "objects"))
stopifnot(json_array_shape(list(ok = TRUE, fields = list()), "fields"))
stopifnot(json_array_shape(list(ok = TRUE, fields = list(list(apiName = "Id", label = "Record ID", type = "id"))), "fields"))
stopifnot(identical(safe_metadata_label("_MISSING LABEL_", "OddObject__c"), "OddObject__c"))
stopifnot(isTRUE(is_missing_metadata_label("__MISSING LABEL__ PropertyFile - value not found")))
stopifnot(isTRUE(is_missing_metadata_label("_MISSING_LABEL_")))
stopifnot(isFALSE(is_missing_metadata_label("Normal Label")))
stopifnot(identical(safe_metadata_label("", "OddField__c"), "OddField__c"))
stopifnot(identical(safe_metadata_label("Normal Label", "OddField__c"), "Normal Label"))
cat("Metadata JSON shape tests passed.\n")
