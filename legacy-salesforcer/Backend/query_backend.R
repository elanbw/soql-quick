#!/usr/bin/env Rscript

# SOQL Quick's only Salesforce operation is sf_query(). Query text and results
# travel through stdin/stdout and are never written to disk.

resource_dir <- Sys.getenv("SOQL_QUICK_RESOURCE_DIR")
if (!nzchar(resource_dir)) {
  file_arg <- commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))][1L]
  resource_dir <- dirname(normalizePath(gsub("~\\+~", " ", sub("^--file=", "", file_arg))))
}
source(file.path(resource_dir, "backend_common.R"))

cell_string <- function(value) {
  if (length(value) == 0L || is.null(value) || (length(value) == 1L && is.na(value))) return("")
  if (is.list(value) || length(value) > 1L) {
    return(jsonlite::toJSON(value, auto_unbox = TRUE, null = "null", na = "null"))
  }
  if (inherits(value, "POSIXt")) return(format(value, "%Y-%m-%dT%H:%M:%S%z"))
  if (inherits(value, "Date")) return(format(value, "%Y-%m-%d"))
  as.character(value)
}

tryCatch({
  request <- read_request()
  query <- trimws(as.character(request$query %||% ""))
  if (!nzchar(query)) stop("Enter a SOQL query before running it.")

  if (identical(Sys.getenv("SOQL_QUICK_MOCK"), "1")) {
    emit(list(
      ok = TRUE,
      columns = array_values(c("Id", "Name", "Amount")),
      textColumns = array_values(c(TRUE, TRUE, FALSE)),
      rows = list(
        list("001000000000001", "Synthetic Example", "-12.5"),
        list("001000000000002", "=SAFE TEST", "3")
      ),
      total = 2L
    ))
  }
  authenticate_salesforce(interactive_login = TRUE)
  data <- salesforcer::sf_query(query, api_type = "REST", guess_types = TRUE)
  if (!is.data.frame(data)) data <- as.data.frame(data, stringsAsFactors = FALSE)

  columns <- names(data)
  text_columns <- if (length(columns)) {
    vapply(data, function(column) is.character(column) || is.factor(column), logical(1))
  } else logical()
  row_count <- nrow(data)
  rows <- if (row_count > 0L && length(columns) > 0L) {
    lapply(seq_len(row_count), function(row_index) {
      unname(lapply(data, function(column) cell_string(column[[row_index]])))
    })
  } else list()

  emit(list(
    ok = TRUE,
    columns = array_values(columns),
    textColumns = array_values(text_columns),
    rows = rows,
    total = row_count
  ))
}, error = function(error) {
  emit(list(ok = FALSE, kind = "query", message = sanitize_error(error)), 1L)
})
