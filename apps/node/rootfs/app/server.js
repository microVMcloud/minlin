require('http').createServer((req, res) => {
    console.log(req.method, req.url);
    res.end(`hello from node ${process.version} on ${require('os').release()}\n`);
}).listen(80);
