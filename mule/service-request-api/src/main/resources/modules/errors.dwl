%dw 2.0
// One shape for every error the API returns, so clients and support staff
// always get a code, a plain message and the correlation id to quote.
fun errorBody(code: String, message: String, corrId: String, details: Array<String> = []) = {
    code: code,
    message: message,
    correlationId: corrId,
    (details: details) if (!isEmpty(details))
}
