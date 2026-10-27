result_prefix <- "SOQL_QUICK_RESULT:"

`%||%` <- function(left, right) {
  if (is.null(left) || length(left) == 0L) right else left
}

emit <- function(payload, status = 0L) {
  cat(result_prefix, jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"), "\n", sep = "")
  quit(save = "no", status = status, runLast = FALSE)
}

sanitize_error <- function(error) {
  message <- conditionMessage(error)
  if (grepl("failed to create server|address already in use", message, ignore.case = TRUE)) {
    return(paste(
      "Salesforce login could not start because local callback port 1410 is already in use.",
      "Quit any older SOQL Quick or R login process, then try again."
    ))
  }
  message <- gsub("(?i)(access[_ ]?token|refresh[_ ]?token|client[_ ]?secret|password)\\s*[:=]\\s*[^[:space:],;]+", "\\1=[REDACTED]", message, perl = TRUE)
  substr(message, 1L, 4000L)
}

required_packages <- c("salesforcer", "jsonlite", "httpuv")
missing_packages <- required_packages[!vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_packages) > 0L) {
  if ("jsonlite" %in% missing_packages) {
    cat(result_prefix, '{"ok":false,"kind":"dependency","message":"Missing R package: jsonlite."}', "\n", sep = "")
    quit(save = "no", status = 2L, runLast = FALSE)
  }
  emit(list(ok = FALSE, kind = "dependency", message = paste("Missing R packages:", paste(missing_packages, collapse = ", "))), 2L)
}

read_request <- function() {
  input <- paste(readLines(file("stdin"), warn = FALSE), collapse = "\n")
  if (!nzchar(trimws(input))) stop("The app did not provide a request.")
  jsonlite::fromJSON(input, simplifyVector = TRUE)
}

array_values <- function(values) unname(as.list(values))

safe_metadata_label <- function(label, api_name) {
  candidate <- if (is.null(label) || length(label) == 0L) "" else trimws(as.character(label[[1L]]))
  if (!nzchar(candidate) || is_missing_metadata_label(candidate)) as.character(api_name) else candidate
}

is_missing_metadata_label <- function(label) {
  if (is.null(label) || length(label) == 0L) return(FALSE)
  grepl("MISSING[[:space:]_]*LABEL", as.character(label[[1L]]), ignore.case = TRUE)
}

oauth_cache_path <- function() {
  cache_dir <- path.expand("~/Library/Application Support/SOQL Quick")
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE, mode = "0700")
  cache_path <- file.path(cache_dir, ".httr-oauth-salesforcer")
  if (file.exists(cache_path) && isTRUE(file.info(cache_path)$size == 0)) unlink(cache_path)
  cache_path
}

enable_macos_oauth_browser <- function() {
  httr_namespace <- asNamespace("httr")
  unlockBinding("BROWSE", httr_namespace)
  assign("BROWSE", function(url = NULL, config = list(), ..., handle = NULL) {
    if (is.null(url) || !nzchar(url)) stop("Salesforce did not provide an authorization URL.")
    status <- system2("/usr/bin/open", shQuote(url), stdout = FALSE, stderr = FALSE, wait = FALSE)
    if (!identical(status, 0L)) stop("macOS could not open the Salesforce authorization page.")
    invisible(url)
  }, envir = httr_namespace)
  lockBinding("BROWSE", httr_namespace)
}

authenticate_salesforce <- function(interactive_login = TRUE) {
  cache_path <- oauth_cache_path()
  if (!interactive_login && !file.exists(cache_path)) {
    emit(list(ok = FALSE, kind = "auth_required", message = "Connect Salesforce to load schema metadata."), 3L)
  }
  if (interactive_login) {
    enable_macos_oauth_browser()
    salesforcer::sf_auth(cache = cache_path)
  } else {
    cached <- try(readRDS(cache_path), silent = TRUE)
    if (inherits(cached, "try-error") || !is.list(cached)) {
      emit(list(ok = FALSE, kind = "auth_required", message = "Reconnect Salesforce to refresh schema metadata."), 3L)
    }
    tokens <- Filter(function(value) inherits(value, "Token2.0"), cached)
    if (length(tokens) == 0L) {
      emit(list(ok = FALSE, kind = "auth_required", message = "Reconnect Salesforce to refresh schema metadata."), 3L)
    }
    salesforcer::sf_auth(token = tokens[[1L]])
  }
}

script_directory <- function() {
  file_arg <- commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))][1L]
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
