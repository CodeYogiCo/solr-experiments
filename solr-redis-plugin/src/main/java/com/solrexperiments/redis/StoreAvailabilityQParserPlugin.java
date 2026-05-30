package com.solrexperiments.redis;

import org.apache.lucene.index.LeafReaderContext;
import org.apache.lucene.index.NumericDocValues;
import org.apache.lucene.search.IndexSearcher;
import org.apache.lucene.search.Query;
import org.apache.lucene.search.QueryVisitor;
import org.apache.solr.common.params.SolrParams;
import org.apache.solr.common.util.NamedList;
import org.apache.solr.request.SolrQueryRequest;
import org.apache.solr.search.DelegatingCollector;
import org.apache.solr.search.ExtendedQueryBase;
import org.apache.solr.search.PostFilter;
import org.apache.solr.search.QParser;
import org.apache.solr.search.QParserPlugin;
import org.apache.solr.search.SyntaxError;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;

import java.io.IOException;
import java.util.Objects;

/**
 * Query parser that produces a {@link PostFilter} removing documents that are
 * not in stock at a given retail store, according to a Redis bitmap.
 *
 * <p>Registered in solrconfig.xml as a {@code <queryParser>} and invoked as a
 * filter query:
 *
 * <pre>
 *   fq={!store_avail id=1234}
 *   fq={!store_avail id=1234 field=sku}
 * </pre>
 *
 * <p>Local params:
 * <ul>
 *   <li>{@code id}    – retail store ID (required). The bitmap key is
 *                       {@code store:{id}:availability}.</li>
 *   <li>{@code field} – numeric SKU field to look up per doc (default "sku").
 *                       Must have docValues.</li>
 * </ul>
 *
 * <p>Because filtering happens inside the collection chain (before the top-N
 * collector), {@code rows}, {@code start} and {@code numFound} all reflect the
 * post-filtered result set — unlike post-hoc trimming of the response.
 */
public class StoreAvailabilityQParserPlugin extends QParserPlugin {

    static final String PARAM_STORE_ID = "id";
    static final String PARAM_FIELD    = "field";
    static final String DEFAULT_FIELD  = "sku";

    static final String BITMAP_KEY_PREFIX = "store:";
    static final String BITMAP_KEY_SUFFIX = ":availability";

    /** Post-filters must have cost >= 100 to be applied after cheaper filters. */
    static final int POST_FILTER_COST = 100;

    @Override
    public void init(NamedList<?> args) {
        // Redis connection config lives on the <queryParser> element.
        RedisConnectionManager.getInstance().init(args);
    }

    @Override
    public QParser createParser(String qstr, SolrParams localParams,
                                SolrParams params, SolrQueryRequest req) {
        return new QParser(qstr, localParams, params, req) {
            @Override
            public Query parse() throws SyntaxError {
                String storeId = localParams == null ? null : localParams.get(PARAM_STORE_ID);
                if (storeId == null || storeId.isBlank()) {
                    throw new SyntaxError("store_avail filter requires a store '"
                            + PARAM_STORE_ID + "' local param, e.g. {!store_avail id=1234}");
                }
                String field = localParams.get(PARAM_FIELD, DEFAULT_FIELD);
                return new StoreAvailabilityPostFilter(storeId, field);
            }
        };
    }

    /**
     * A non-cached, high-cost query that filters via a Redis bitmap lookup
     * during collection.
     */
    static final class StoreAvailabilityPostFilter extends ExtendedQueryBase implements PostFilter {

        private static final Logger log =
                LoggerFactory.getLogger(StoreAvailabilityPostFilter.class);

        private final String storeId;
        private final String field;
        private final String bitmapKey;

        StoreAvailabilityPostFilter(String storeId, String field) {
            this.storeId = storeId;
            this.field = field;
            this.bitmapKey = BITMAP_KEY_PREFIX + storeId + BITMAP_KEY_SUFFIX;
            setCache(false);            // a post-filter is not a cacheable filter
            setCost(POST_FILTER_COST);  // ensure it runs as a post-filter
        }

        String bitmapKey() {
            return bitmapKey;
        }

        @Override
        public boolean getCache() {
            return false;
        }

        @Override
        public int getCost() {
            return Math.max(super.getCost(), POST_FILTER_COST);
        }

        @Override
        public DelegatingCollector getFilterCollector(IndexSearcher searcher) {
            final JedisPool pool = RedisConnectionManager.getInstance().getPool();
            return new DelegatingCollector() {
                private NumericDocValues skuValues;
                private Jedis jedis;

                @Override
                protected void doSetNextReader(LeafReaderContext context) throws IOException {
                    super.doSetNextReader(context);
                    // SKU docValues are per-segment; refresh on each leaf.
                    this.skuValues = context.reader().getNumericDocValues(field);
                }

                @Override
                public void collect(int doc) throws IOException {
                    if (jedis == null) {
                        jedis = pool.getResource();
                    }
                    if (skuValues != null && skuValues.advanceExact(doc)) {
                        long sku = skuValues.longValue();
                        if (sku >= 0 && jedis.getbit(bitmapKey, sku)) {
                            super.collect(doc);
                        }
                    }
                    // No docValues for this doc, or bit unset → drop it.
                }

                @Override
                public void complete() throws IOException {
                    // finish() is final in DelegatingCollector; complete() is the
                    // end-of-search hook where we return the pooled connection.
                    try {
                        super.complete();
                    } finally {
                        if (jedis != null) {
                            try {
                                jedis.close();
                            } catch (Exception e) {
                                log.warn("Failed returning Jedis connection to pool", e);
                            }
                            jedis = null;
                        }
                    }
                }
            };
        }

        @Override
        public void visit(QueryVisitor visitor) {
            visitor.visitLeaf(this);
        }

        @Override
        public String toString(String f) {
            return "StoreAvailabilityPostFilter(store=" + storeId + ", field=" + field + ")";
        }

        @Override
        public boolean equals(Object o) {
            if (this == o) return true;
            if (!(o instanceof StoreAvailabilityPostFilter other)) return false;
            return bitmapKey.equals(other.bitmapKey) && field.equals(other.field);
        }

        @Override
        public int hashCode() {
            return Objects.hash(classHash(), bitmapKey, field);
        }
    }
}
