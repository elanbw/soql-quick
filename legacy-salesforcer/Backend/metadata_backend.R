#!/usr/bin/env Rscript

resource_dir <- Sys.getenv("SOQL_QUICK_RESOURCE_DIR")
if (!nzchar(resource_dir)) {
  file_arg <- commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))][1L]
  resource_dir <- dirname(normalizePath(gsub("~\\+~", " ", sub("^--file=", "", file_arg))))
}
source(file.path(resource_dir, "backend_common.R"))

scalar <- function(value, default = NA) {
  if (is.null(value) || length(value) == 0L) default else value[[1L]]
}

tryCatch({
  request <- read_request()
  operation <- as.character(request$operation %||% "")
  auth_mode <- as.character(request$authMode %||% "cached")

  if (identical(Sys.getenv("SOQL_QUICK_MOCK"), "1")) {
    if (operation == "list_objects") {
      emit(list(ok = TRUE, objects = list(
        list(apiName = "Account", label = "Account", custom = FALSE, queryable = TRUE),
        list(apiName = "Annual_Project_Record__c", label = "Annual Project Record", custom = TRUE, queryable = TRUE)
      )))
    }
    emit(list(ok = TRUE, objectApiName = request$objectApiName %||% "Account", fields = list(
      list(apiName = "Id", label = "Record ID", type = "id", custom = FALSE, calculated = FALSE, nillable = FALSE, filterable = TRUE, sortable = TRUE, relationshipName = NA, referenceTo = list()),
      list(apiName = "Account__c", label = "Account", type = "reference", custom = TRUE, calculated = FALSE, nillable = TRUE, filterable = TRUE, sortable = TRUE, relationshipName = "Account__r", referenceTo = list("Account"))
    )))
  }

  authenticate_salesforce(interactive_login = identical(auth_mode, "interactive"))

  if (operation == "list_objects") {
    described <- salesforcer::sf_list_objects()$sobjects
    described <- Filter(function(object) !is_missing_metadata_label(object$label), described)
    objects <- lapply(described, function(object) {
      api_name <- as.character(scalar(object$name, ""))
      list(
        apiName = api_name,
        label = safe_metadata_label(object$label, api_name),
        custom = isTRUE(scalar(object$custom, FALSE)),
        queryable = isTRUE(scalar(object$queryable, FALSE))
      )
    })
    objects <- Filter(function(object) isTRUE(object$queryable) && nzchar(object$apiName), objects)
    emit(list(ok = TRUE, objects = objects))
  }

  if (operation == "describe_object") {
    object_name <- as.character(request$objectApiName %||% "")
    if (!nzchar(object_name)) stop("No Salesforce object was selected.")
    described <- salesforcer::sf_describe_objects(object_name, api_type = "REST")[[1L]]
    fields <- lapply(described$fields %||% list(), function(field) {
      api_name <- as.character(scalar(field$name, ""))
      list(
        apiName = api_name,
        label = safe_metadata_label(field$label, api_name),
        type = as.character(scalar(field$type, "unknown")),
        custom = isTRUE(scalar(field$custom, FALSE)),
        calculated = isTRUE(scalar(field$calculated, FALSE)),
        nillable = isTRUE(scalar(field$nillable, TRUE)),
        filterable = isTRUE(scalar(field$filterable, FALSE)),
        sortable = isTRUE(scalar(field$sortable, FALSE)),
        relationshipName = scalar(field$relationshipName, NA_character_),
        referenceTo = array_values(as.character(field$referenceTo %||% character()))
      )
    })
    emit(list(ok = TRUE, objectApiName = object_name, fields = fields))
  }

  stop("Unknown metadata operation.")
}, error = function(error) {
  emit(list(ok = FALSE, kind = "metadata", message = sanitize_error(error)), 1L)
})
