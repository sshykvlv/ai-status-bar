import Foundation

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var errorHandler: ((URLRequest) -> Error)?
    /// Alternate to `handler`, checked first — hands back a raw URLResponse instead of
    /// wrapping a status code in HTTPURLResponse. Lets tests simulate a non-HTTP response
    /// (e.g. to prove `as? HTTPURLResponse` guards degrade gracefully instead of crashing).
    static var rawHandler: ((URLRequest) -> (URLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let errorHandler = Self.errorHandler {
            client?.urlProtocol(self, didFailWithError: errorHandler(request))
            return
        }
        if let rawHandler = Self.rawHandler {
            let (resp, data) = rawHandler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let (status, data) = Self.handler!(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension URLSession {
    static var mocked: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}
