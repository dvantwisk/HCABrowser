## https://dss.integration.data.humancellatlas.org/

.apis <- c(
    getBundlesCheckout = "/bundles/%s/checkout",
    deleteBundle = "/bundles/%s",
    getBundle = "/bundles/%s",
    putBundle = "/bundles/%s",
    postBundlesCheckout = "/bundles/%s/checkout",
    putCollection = "/collections",
    deleteCollection = "/collections/%s",
    getCollection = "/collections/%s",
    patchCollection = "/collections/%s",
    getFile = "/files/%s",
    headFile = "/files/%s",
    putFile = "/files/%s",
    postSearch = "/search",
    getSubscriptions = "/subscriptions",
    putSubscriptions = "/subscriptions",
    deleteSubscriptions = "/subscriptions/%s",
    getSubscription = "/subscriptions/%s"
)

.build_url <- function(url, tag, uuid=NULL, args=NULL){
    if(!is.null(uuid)) tag <- sprintf(tag, uuid)
    url <- paste0(url, tag)
    if(!is.null(args)) {
        args[vapply(args, is.null, logical(1))] <- NULL
        args <- paste0(names(args), rep("=", length(args)), as.character(args))
        args <- paste0(args, collapse="&")
        url <- paste0(url, "?", args)
    }
    url
}

#' @importFrom httr add_headers
.build_header <- function(include_token)
{
    header <- list(
        `Content-Type` = "application/json",
        `Accept` = "application/json"
    )
    if (include_token) {
        token <- get_token()
        header['access_token'] <- token$credentials[['access_token']]
        header['token_type'] <- token$credentials[['token_type']]
        header['expires_in'] <- token$credentials[['expires_in']]
    }
    do.call(add_headers, header)
}

#' @importFrom BiocFileCache BiocFileCache bfcnew bfcrpath bfccache
.retrieve_BiocFileCache_dbpath <- function(url)
{
    if (is.null(dbpath))
        dbpath <- BiocFileCache()
    if (methods::is(dbpath, "BiocFileCache")) {
        nrec <- NROW(bfcquery(dbpath, url, "rname", exact = TRUE))
        if (nrec == 0L)
            dbpath <- bfcnew(dbpath, url)
        else if (nrec == 1L)
            dbpath <- bfcrpath(dbpath, url)
        else
            stop(
                "\n  'bfc' contains duplicate record names",
                    "\n      url: ", url,
                    "\n      bfccache(): ", bfccache(dbpath),
                    "\n      rname: ", bfccache(dbpath)$rname
            )
    }
}

#' @importFrom readr read_tsv
.save_as_BiocFileCache <- function(dbpath, url)
{
    fname <- BiocFileCache::bfcrpath(rnames = url)
    readr::read_tsv(fname)
}

#' @importFrom httr content stop_for_status
#' @importFrom jsonlite fromJSON
.return_response <-
    function(response, expected_response=c('json', 'file'))
{
    expected_response <- match.arg(expected_response)
    stop_for_status(response)
    suppressMessages(response <- content(response, as = "text"))
    if (expected_response == 'json')
        fromJSON(response, simplifyDataFrame=FALSE, simplifyMatrix=FALSE,
            flatten=FALSE)
    else if (expected_response == 'file')
        readr::read_tsv(file=response)
}

#' @importFrom httr DELETE
.hca_delete <-
    function(url, body)
{
    header <- .build_header(include_token=TRUE)
    response <- httr::DELETE(url, header, body=body, encode="json")
    .return_response(response)
} 

#' @importFrom httr GET
.hca_get <-
    function(url, include_token)
{
    header <- .build_header(include_token)
    if(include_token) response <- httr::GET(url, header)
    else response <- httr::GET(url)   
    .return_response(response)
}

#' @importFrom BiocFileCache BiocFileCache bfcrpath bfcquery bfcnew bfccount
#' @importFrom httr write_disk
.hca_get_file <-
    function(url, include_token)
{
    url_split <- unlist(strsplit(url, '?', fixed = TRUE))
    ## Include 2 parts one is the unique identifier without extra "relpica", etc.
    ## rname <- url1
    ## if(bfccount(bfcquery(bfc, rname)) == 0) bfcnew(bfc, rname) else bfcrpath(bfc, rname)
    bfc <- BiocFileCache()
    rname <- url_split[1]
    if (bfccount(bfcquery(bfc, rname)) == 0) {
        path = bfcnew(bfc, rname)
        httr::GET(url, write_disk(path))
    }
    bfcrpath(bfc, rname)
#    header <- .build_header(include_token)
#    if(include_token) response <- httr::GET(url, header)
#    else response <- httr::GET(url)   
#    .return_response(response)
}

#' @importFrom httr HEAD
.hca_head <-
    function(url)
{
    header <- .build_header(include_token=FALSE)
    response <- httr::HEAD(url, header)
    .return_response(response)
}

#' @importFrom httr PATCH
.hca_patch <-
    function(url, body)
{
    header <- .build_header(include_token=TRUE)
    response <- httr::PATCH(url, header, body=body, encode="json")
    .return_response(response)
}

.hca_post_get_response <-
    function(url, body)
{
    header <- .build_header(include_token=FALSE)
    if (is.character(body))
        httr::POST(url, header, body=body, encode="raw")#, httr::verbose())
    else
        httr::POST(url, header, body=body, encode="json")#, httr::verbose())
}

.hca_post_parse_response <-
    function(response, first_hit)
{
    res <- .return_response(response)
    link <- httr::headers(response)[['link']]
    if (is.null(link))
        link <- character(0)
    else
        link <- str_replace(link, '<(.*)>.*', '\\1')
    results <- .parse_postSearch_results(res[['results']])
    if (length(res[['results']]) == 0) {
        first_hit <- 0L
        last_hit <- 0L
    }
    else
        last_hit <- length(res[['results']]) + first_hit - 1L
    .SearchResult(results = as_tibble(results),
        total_hits = res[['total_hits']], link=link, first_hit = first_hit,
        last_hit = last_hit)
}

#' @importFrom dplyr as_tibble
#' @importFrom httr POST headers
#' @importFrom stringr str_replace
.hca_post <-
    function(url, body, first_hit = 1L)
{
    response <- .hca_post_get_response(url, body)
    .hca_post_parse_response(response, first_hit)
}

.nextResults_HCABrowser <- function(result)
{
    sr <- result@results
    if (length(sr@link) > 0) {
        es_query <- result@search_term
        if (length(result@search_term) == 0)
            es_query <- list(es_query = list(query = list(bool = NULL)))
        result@results <- .hca_post(link(sr),
            body = es_query,
            first_hit = last_hit(sr) + 1L)
        result
    }
    else
        NULL
}

#' @importFrom httr PUT
.hca_put <-
    function(hca, url, body, include_token)
{
    header <- .build_header(include_token)
    response <- httr::PUT(hca@url, header, body, encode="json")
    .return_response(response)
}

.getBundlesCheckout <-
    function(hca, checkout_job_id, replica=c('aws', 'gcp', 'azure'))
{
    replica <- match.arg(replica)
    args <- list(replica=replica)
    url <- .build_url(hca@url, .apis['getBundlesCheckout'], checkout_job_id, args)
    .hca_get(url, include_token=FALSE)
}

.deleteBundle <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'), version=NULL,
        reason = NULL)
{
    replica <- match.arg(replica)
    args <- list(replica=replica, version=version)
    url <- .build_url(hca@url, .apis['deleteBundle'], uuid, args)
    .hca_delete(url)
}

.getBundle <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'), version=NULL,
        directurls=NULL, presignedurls=FALSE, token=NULL)
{
    replica <- match.arg(replica)
    args <- list(replica=replica, version=version, directurls=directurls,
                  presignedurls=presignedurls, token=token)
    url <- .build_url(hca@url, .apis['getBundle'], uuid, args)
    .hca_get(url, include_token=FALSE)
}

.putBundle <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'), version=NULL,
        creator_uid, files)
{
    replica <- match.arg(replica)
    args <- list(replica=replica, version=version)
    body <- list(creator_uid=creator_uid, files=files)
    url <- .build_url(hca@url, .apis['putBundle'], uuid, args)
    .hca_put(url, body, include_token=FALSE)
}

.postBundlesCheckout <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'), destination=NULL,
        email=NULL)
{
    replica <- match.arg(replica)
    args <- list(replica=replica, version=version)
    body <- list(destination=destination, email=email)
    url <- .build_url(hca@url, .apis['postBundlesCheckout'], uuid, args)
    .hca_post(url, body)
}

.putCollection <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'), version, contents,
        description, details, name)
{
    replica <- match.arg(replica)
    body <- list(contents=contents, description=description, details=details,
                 name=name)
    url <- .build_url(hca@url, .apis['putCollection'], uuid, NULL)
    .hca_put(url, body, include_token=TRUE)
}

.deleteCollection <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'))
{
    replica <- match.arg(replica)
    args <- list(replica=replica)
    url <- .build_url(hca@url, .apis['deleteCollection'], uuid, args)
    .hca_delete(url)
}

.getCollection <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'), version=NULL)
{
    replica <- match.arg(replica)
    args <- list(replica=replica, version=version)
    url <- .build_url(hca@url, .apis['getCollection'], uuid, args)
    .hca_get(url, include_token=TRUE)
}

.patchCollection <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'), version, add_contents,
        description, details, name, remove_contents)
{
    replica <- match.arg(replica)
    args <- list(replica=replica, version=version)
    body <- list(add_contents=add_contents, description=description,
                 details=details, name=name, remove_contents=remove_contents)
    url <- .build_url(hca@url, .apis['patchCollection'], uuid, args)
    .hca_patch(url, body)
}

.getFile <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'), token=NULL, version=NULL)
{
    replica <- match.arg(replica)
    args <- list(replica=replica, version=version, token=token)
    paths <- vapply(uuid, function(x) {
        url <- .build_url(hca@url, .apis['getFile'], x, args)
        .hca_get_file(url, include_token=FALSE)
    }, character(1))
    as_tibble(data.frame(uuid = uuid, path = paths))
}

.headFile <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'), version=NULL)
{
    replica <- match.arg(replica)
    args <- list(replica=replica, version=version)
    url <- .build_url(hca@url, .apis['getFile'], uuid, args)
    .hca_head(url)
}

.putFile <-
    function(hca, uuid, creator_uid, source_url, version=NULL)
{
    replica <- match.arg(replica)
    args <- list(version=version)
    body <- list(creator_uid=creator_uid, source_url=source_url)
    url <- .build_url(hca@url, .apis['putFile'], uuid, args)
    .hca_put(url, body, include_token=FALSE)
}

.postSearch <-
    function(hca, replica=c('aws', 'gcp', 'azure'),
        output_format=c('summary', 'raw'), es_query=NULL, per_page=100,
        search_after=NULL, json=NULL)
{
    replica <- match.arg(replica)
    output_format <- match.arg(output_format)
    args <- list(replica=replica, output_format=output_format,
                 per_page=per_page, search_after=search_after)
    if (is.null(es_query)) {
        es_query <- hca@search_term
        if (length(es_query) == 0)
            es_query <- list(es_query = list(query = list(bool = NULL)))
    }
    body <- es_query
    if (!is.null(json))
        body <- json
    url <- .build_url(hca@url, .apis['postSearch'], NULL, args)
    post_res <- .hca_post(url, body)
    hca@results <- post_res
    hca
}

.getSubscriptions <-
    function(hca, replica=c('aws', 'gcp', 'azure'))
{
    replica <- match.arg(replica)
    args <- list(replica=replica)
    url <- .build_url(hca@url, .apis['getSubscriptions'], NULL, args)
    .hca_get(url, include_token=TRUE)
}

.putSubscription <-
    function(hca, replica=c('aws', 'gcp', 'azure'), attachments, callback_url,
        encoding, es_query, form_fields, hmac_key_id, hmac_secret_key,
        method, payload_form_field)
{
    replica <- match.arg(replica)
    args <- list(replica=replica)
    body <- list(attachments=attachments, callback_url=callback_url,
                 encoding=encoding, es_query=es_query, form_fields=form_fields,
                 hmac_key_id=hmac_key_id, hmac_secret_key=hmac_secret_key,
                 method=method, payload_form_field=payload_form_field)
    url <- .build_url(hca@url, .apis['putSubscription'], NULL, args)
    .hca_put(url, body, include_token=TRUE)
}

.deleteSubscription <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'))
{
    replica <- match.arg(replica)
    args <- list(replica=replica)
    url <- .build_url(hca@url, .apis['deleteSubscription'], uuid, args)
    .hca_delete(url)
}

.getSubscription <-
    function(hca, uuid, replica=c('aws', 'gcp', 'azure'))
{
    replica <- match.arg(replica)
    args <- list(replica=replica)
    url <- .build_url(hca@url, .apis['getSubscription'], uuid, args)
    .hca_get(url, include_token=TRUE)
}

#' HCA API methods
#'
#' @aliases getBundlesCheckout deleteBundle getBundle putBundle
#'      postBundlesCheckout putCollection deleteCollection getCollection
#'      patchCollection getFile headFile putFile postSearch getSubscriptions
#'      putSubscription deleteSubscription getSubscription
#'
#' @description
#'
#' Methods to access the Human Cell Atlas's Data Coordination Platform (HCA DCP)
#' by means of the platform's REST API.
#'
#' @usage
#'
#' getBundlesCheckout(hca, ...)
#' deleteBundle(hca, ...)
#' getBundle(hca, ...)
#' putBundle(hca, ...)
#' postBundlesCheckout(hca, ...)
#' putCollection(hca, ...)
#' deleteCollection(hca, ...)
#' getCollection(hca, ...)
#' patchCollection(hca, ...)
#' getFile(hca, ...)
#' headFile(hca, ...)
#' putFile(hca, ...)
#' postSearch(hca, ...)
#' getSubscriptions(hca, ...)
#' putSubscription(hca, ...)
#' deleteSubscription(hca, ...)
#' getSubscription(hca, ...)
#' 
#' @param add_contents list. List of items to remove from the collection. Items
#'  must match exactly to be removed. Items not found in the collection are
#'  ignored. (ADD DESCRIPTION OF LIST OBJECT)
#'
#' @param attachments list. The set of bundle metadata items to be included in
#'  the payload of a notification request to a subscriptionendpoint. Each
#'  property in this object represents an attachment to the notification
#'  payload. Each attachment will be a child property of the "attachments"
#'  property of the payload. The name of such a child property can be chosen
#'  freely provided it does not start with an underscore. For example, if the
#'  subscription is ``` { "attachments": { "taxon": { "type": "jmespath",
#'  "expression": "files.biomaterial_j
#'  son.biomaterials[].content.biomaterial_core.ncbi_taxon_id[]" } } } ``` the
#'  corresponding notification payload will contain the following entry ```
#'  "attachments": { "taxon": [9606, 9606] } ``` If a general error occurs
#'  during the processing of attachments, the notification will be sent with
#'  `attachments` containing only the reserved `_errors` attachment containing a
#'  string describing the error. If an error occurs during the processing of a
#'  specific attachment, the notification will be sent with all
#'  successfully processed attachments and additionally
#'  the `_errors` attachment containing an object with one
#'  property for each failed attachment. For example, ```
#'  "attachments": { "taxon": [9606, 9606] "_errors" {
#'  "biomaterial": "Some error occurred" } } ``` The value
#'  of the `attachments` property must be less than or
#'  equal to 128 KiB in size when serialized to JSON and
#'  encoded as UTF-8. If it is not, the notification will
#'  be sent with "attachments": { "_errors": "Attachments
#'  too large (131073 bytes)" }
#'
#' @param callback_url character(1).
#'  The subscriber's URL. An HTTP request is made to the
#'  specified URL for every attempt to deliver a
#'  notification to the subscriber. If the HTTP response
#'  code is 2XX, the delivery attempt is considered
#'  successful and no more attemtpts will be made.
#'  Otherwise, more attempts will be made with an
#'  exponentially increasing delay between attempts, until
#'  an attempt is successful or the a maximum number of
#'  attempts is reached.
#'
#' @param checkout_job_id character(1). A RFC4122-complliant ID for the checkout
#'  job request.
#'
#' @param contents list. A list of objects describing links to files, bundles,
#'  other collections, and metadata fragments that are part of the collection.
#'
#' @param creator_uid character(1). User ID who is creating this bundle.
#'
#' @param description character(1). A long description of the collection,
#'  formatted in Markdown.
#'
#' @param destination character(1). User-owned destination storage bucket.
#'
#' @param details list. Supplementary JSON metadata for the collection.
#'  (ADD DESCRIPTION OF STRUCTURE)
#'
#' @param directurls logical(1). Include direct-access URLs in the response.
#'  This is mutually exclusive with the \code{presignedurls} parameter.  DEFAULT
#'  is \code{NULL}.
#'
#' @param email character(1). An email address to send status updates to.
#'
#' @param encoding character(1). The MIME type describing the encoding of the
#'  request body.  Either "application/json" or "multipart/form-data".
#'
#' @param es_query list. Elasticsearch query. (ADD DESCRIPTION OF STRUCTURE)
#'
#' @param files list. (ADD DESCRIPTION ON STRUCTURE OF THIS ARGUMENT)
#'
#' @param form_fields list. A collection of static form fields to be supplied in
#'  the request body, alongside the actual notification payload.
#'
#' @param hca An HCABrowser object that is the subject of the request.
#'
#' @param hmac_key_id character(1). An optional key ID to use with
#'  "hmac_secret_key".
#'
#' @param hmac_secret_key character(1). The key for signing requests to the
#'  subscriber's URL. The signature will be constructed according to
#'  https://tools.ietf.org/html/draft-cavage-http-signatures and transmitted in
#'  the HTTP `Authorization` header.
#'
#' @param json character(1) of a json query to be executed.
#'
#' @param method The HTTP request method to use when delivering a notification
#'  to the subscriber.
#'
#' @param name character(1). A short name identifying the collection.
#'
#' @param output_format character(1). Specifies the output format. Either
#'  "summary" or "raw". The default format, "summary", is a list of UUIDs for
#'  bundles that match the query. Set this parameter to "raw" to get the
#'  verbatim JSON metadata for bundles that match the query.
#'
#' @param payload_form_field character(1). The name of the form field that will
#'  hold the notification payload when the request is made. If the default name
#'  of the payload field collides with that of a field in `form_fields`, this
#'  porperty can be used to rename the payload and avoid the collision. This
#'  property is ignored unless `encoding` is `multipart/form-data`.
#'
#' @param per_page numeric(1). Max number of results to return per page.
#'
#' @param presignedurls logical(1). Include presigned URLs in the response. This
#'   is mutually exclusive with the directurls parameter.
#'
#' @param reason character(1). User-friendly reason for the bundle or timestamp-
#'   specific bundle deletion.
#'
#' @param remove_contents list. List of items to remove from the collection.
#'  Items must match exactly to be removed. Items not found in the collection
#'  are ignored.
#'
#' @param replica character(1). A replica to fetch form. Can either be
#'  set to "aws", "gcp", or "azure".  DEFAULT is "aws".
#'
#' @param search_after character(1). **Search-After-Context**. An internal state
#'  pointer parameter for use with pagination. The API client should not need to
#'  set this parameter directly; it should instead directly fetch the URL given
#'  in the "Link" header.
#'
#' @param source_url character(1). Cloud URL for source data.
#'
#' @param token \code{Token}. Token to manage retries. End users constructing
#'   queries should not set this parameter. Use \code{get_token()} to generate.
#'
#' @param uuid character(1). A RFC4122-compliant ID for the bundle.
#'
#' @param version character(1). Timestamp of bundle creation in RFC3339.
#'
#' @param ... Other arguments
#'
#' @return an HCABrowser object
#'
#' @examples
#' hca <- HCABrowser()
#' #addmore
#' 
#'
#' @name hca-api-methods
#' @author Daniel Van Twisk
NULL
 
#'
#' Check the status of a checkout request 
#'
#' @description Check the status of a checkout request 
#'
#' @rdname hca-api-methods
###' @export
setMethod("getBundlesCheckout", "HCABrowser", .getBundlesCheckout)

#' Delete a bundle or a specific bundle version
#'
#' @rdname hca-api-methods
###' @export
setMethod("deleteBundle", "HCABrowser", .deleteBundle)

#' Retrieve a bundle given a UUID and optionally a version
#'
#' @rdname hca-api-methods
###' @export
setMethod("getBundle", "HCABrowser", .getBundle)

#' Create a bundle
#'
#' @rdname hca-api-methods
###' @export
setMethod("putBundle", "HCABrowser", .putBundle)

#' Check out a bundle to DSS-namaged or user-managed cloud object storage
#' destination
#'
#' @rdname hca-api-methods
###' @export
setMethod("postBundlesCheckout", "HCABrowser", .postBundlesCheckout)

#' Create a collection
#'
#' @rdname hca-api-methods
###' @export
setMethod("putCollection", "HCABrowser", .putCollection)

#' Delete a collection
#'
#' @rdname hca-api-methods
###' @export
setMethod("deleteCollection", "HCABrowser", .deleteCollection)

#' Retrieve a collection given a UUID
#'
#' @rdname hca-api-methods
###' @export
setMethod("getCollection", "HCABrowser", .getCollection)

#' Update a collection
#'
#' @rdname hca-api-methods
###' @export
setMethod("patchCollection", "HCABrowser", .patchCollection)

#' Retrieve a file given a UUID and optionally a version
#'
#' @rdname hca-api-methods
#' @export
setMethod("getFile", "HCABrowser", .getFile)

#' Retrieve a file's metadata given an UUID and optionally a version
#'
#' @rdname hca-api-methods
###' @export
setMethod("headFile", "HCABrowser", .headFile)

#' Create a new version of a file
#'
#' @rdname hca-api-methods
###' @export
setMethod("putFile", "HCABrowser", .putFile)

#' Find bundles by searching their metadata with an Elasticsearch query
#'
#' @rdname hca-api-methods
#'
#' @export
setMethod("postSearch", "HCABrowser", .postSearch)

#' Retrieve a user's event Subscription
#'
#' @rdname hca-api-methods
###' @export
setMethod("getSubscriptions", "HCABrowser", .getSubscriptions)

#' Creates an event subscription
#'
#' @rdname hca-api-methods
###' @export
setMethod("putSubscription", "HCABrowser", .putSubscription)

#' Delete an event subscription
#'
#' @rdname hca-api-methods
###' @export
setMethod("deleteSubscription", "HCABrowser", .deleteSubscription)

#' Retrieve an event subscription given a UUID
#'
#' @rdname hca-api-methods
###' @export
setMethod("getSubscription", "HCABrowser", .getSubscription)

#' Next Results
#'
#' Fetch the next set of bundles from a Human Cell Atlas Object
#'
#' @param result A HCABrowser object that has further bundles to display.
#'
#' @return A Human Cell Atlas object that displays the next results
#'
#' @author Daniel Van Twisk
#'
#' @name nextResults
#' @aliases nextResults,HCABrowser-method
#' @docType methods
#' 
#' @examples
#'
#' hca <- HCABrowser()
#' hca <- nextResults(hca)
#' hca
#'
#' @export
setMethod("nextResults", "HCABrowser", .nextResults_HCABrowser)

