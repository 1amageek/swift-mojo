import Crypto
import Foundation

/// Authority for the resource codec. The live worker remains v1 until endpoint
/// and manifest migration; defining this schema never admits a v2 worker.
package enum MojoRuntimeResourceProtocol {
    package static let version: UInt16 = 2
    package static let invocationPrefixByteCount = 48
    package static let bufferPrefixByteCount = 40
    package static let dimensionByteCount = 16
    package static let outputCapacityByteCount = 12
    package static let resultPrefixByteCount = 44

    package static let schemaDigest: String = {
        let records = [
            "version=2;header=32;magic=SMW1;endianness=little;in-flight=1",
            "kinds=1:ready,2:createSession,3:sessionCreated,4:invoke,5:invocationResult,6:shutdownSession,7:sessionShutdown,8:shutdownWorker,9:workerShutdown,10:failure",
            "invoke=binding:u64,schema:sha256,args:u32,inputs:u16,outputs:u16,descriptors,capacities,arguments,copied-body",
            "buffer=storage:u16,element:u16,rank:u16,zero:u16,ordinal:u32,zero:u32,region:u64,offset:u64,payload-offset:u64,(dimension:u64,stride:u64)*rank",
            "storage=1:copied,2:shared-file,3:dma-buf;copied-ordinal=4294967295;shared-payload-offset=0",
            "elements=1:i8,2:u8,3:i16,4:u16,5:i32,6:u32,7:i64,8:u64,9:f16,10:f32,11:f64",
            "capacity=element:u16,zero:u16,count:u64",
            "result=status:i32,schema:sha256,values:u32,outputs:u16,zero:u16,counts:u64[],values,output-body",
            "rights=one-set-on-first-byte;dense-ordinals;aliases-require-identical-region",
            "completion=all-input-readers-joined;all-output-writers-joined;imports-closed;failure-has-no-output",
            "limits=rank,region,inputs,outputs,argument-bytes,result-value-bytes,control-bytes,copied-bytes,mapped-bytes,result-bytes",
            "empty=binding-declared;scalar-rank=0;positive-strides;readonly-aliases;no-repack",
        ]
        // Length framing prevents ambiguous concatenation of schema records.
        var writer = MojoRuntimeByteWriter()
        for record in records {
            let bytes = Array(record.utf8)
            writer.appendUInt64(UInt64(bytes.count))
            writer.append(contentsOf: bytes)
        }
        return SHA256.hash(data: writer.data())
            .map { String(format: "%02x", $0) }.joined()
    }()
}
