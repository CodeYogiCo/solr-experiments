package com.solrexperiments.redis;

import org.apache.lucene.index.LeafReaderContext;
import org.apache.lucene.index.NumericDocValues;
import org.apache.lucene.index.ReaderUtil;
import org.apache.solr.common.SolrDocument;
import org.apache.solr.common.SolrException;
import org.apache.solr.common.params.SolrParams;
import org.apache.solr.common.util.NamedList;
import org.apache.solr.request.SolrQueryRequest;
import org.apache.solr.response.ResultContext;
import org.apache.solr.response.transform.DocTransformer;
import org.apache.solr.response.transform.TransformerFactory;
import org.apache.solr.search.SolrIndexSearcher;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;

import java.io.IOException;
import java.util.List;

/**
 * Document transformer that annotates each returned document with a boolean
 * {@code storeAvailable} field, looked up from a Redis bitmap. Unlike the
 * {@link StoreAvailabilityQParserPlugin} post-filter, this keeps every matching
 * document and leaves {@code numFound}/facets untouched.
 *
 * <p>Registered in solrconfig.xml as a {@code <transformer>} and invoked in fl:
 *
 * <pre>
 *   fl=*,storeAvailable:[store_avail id=1234]
 *   fl=*,storeAvailable:[store_avail id=1234 field=sku]
 * </pre>
 *
 * <p>The SKU is read from DocValues using the Lucene docid (the same source the
 * post-filter uses). Reading it from the {@link SolrDocument}'s stored fields is
 * unreliable inside a transformer, so we go to DocValues directly.
 */
public class StoreAvailabilityTransformerFactory extends TransformerFactory {

    static final String PARAM_STORE_ID = "id";
    static final String PARAM_FIELD    = "field";
    static final String DEFAULT_FIELD  = "sku";

    static final String BITMAP_KEY_PREFIX = "store:";
    static final String BITMAP_KEY_SUFFIX = ":availability";

    @Override
    public void init(NamedList<?> args) {
        // Redis connection config lives on the <transformer> element.
        RedisConnectionManager.getInstance().init(args);
    }

    @Override
    public DocTransformer create(String field, SolrParams params, SolrQueryRequest req) {
        String storeId = params.get(PARAM_STORE_ID);
        if (storeId == null || storeId.isBlank()) {
            throw new SolrException(SolrException.ErrorCode.BAD_REQUEST,
                    "[store_avail] transformer requires a store '" + PARAM_STORE_ID
                            + "' param, e.g. fl=*,storeAvailable:[store_avail id=1234]");
        }
        String skuField = params.get(PARAM_FIELD, DEFAULT_FIELD);
        return new StoreAvailabilityTransformer(field, storeId, skuField);
    }

    static final class StoreAvailabilityTransformer extends DocTransformer {

        private static final Logger log =
                LoggerFactory.getLogger(StoreAvailabilityTransformer.class);

        private final String outputField;
        private final String skuField;
        private final String bitmapKey;

        private List<LeafReaderContext> leaves;

        StoreAvailabilityTransformer(String outputField, String storeId, String skuField) {
            this.outputField = outputField;
            this.skuField = skuField;
            this.bitmapKey = BITMAP_KEY_PREFIX + storeId + BITMAP_KEY_SUFFIX;
        }

        @Override
        public String getName() {
            return outputField;
        }

        @Override
        public void setContext(ResultContext context) {
            super.setContext(context);
            SolrIndexSearcher searcher = context.getSearcher();
            this.leaves = searcher.getTopReaderContext().leaves();
        }

        @Override
        public void transform(SolrDocument doc, int docid) throws IOException {
            long sku = readSku(docid);
            boolean available = false;
            if (sku >= 0) {
                JedisPool pool = RedisConnectionManager.getInstance().getPool();
                try (Jedis jedis = pool.getResource()) {
                    available = jedis.getbit(bitmapKey, sku);
                } catch (Exception e) {
                    log.warn("Redis availability lookup failed for {} sku={}; "
                            + "annotating as unavailable", bitmapKey, sku, e);
                }
            }
            doc.setField(outputField, available);
        }

        /** Read the SKU for a global docid from DocValues. Returns -1 if absent. */
        private long readSku(int globalDocId) throws IOException {
            if (leaves == null || leaves.isEmpty()) {
                return -1;
            }
            int leafIdx = ReaderUtil.subIndex(globalDocId, leaves);
            LeafReaderContext leaf = leaves.get(leafIdx);
            NumericDocValues dv = leaf.reader().getNumericDocValues(skuField);
            int segDoc = globalDocId - leaf.docBase;
            if (dv != null && dv.advanceExact(segDoc)) {
                return dv.longValue();
            }
            return -1;
        }
    }
}
