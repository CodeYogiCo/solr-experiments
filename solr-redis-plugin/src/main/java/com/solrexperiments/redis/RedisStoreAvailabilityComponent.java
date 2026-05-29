package com.solrexperiments.redis;

import org.apache.lucene.search.TotalHits;
import org.apache.solr.common.SolrDocument;
import org.apache.solr.common.SolrDocumentList;
import org.apache.solr.common.params.SolrParams;
import org.apache.solr.common.util.NamedList;
import org.apache.solr.handler.component.ResponseBuilder;
import org.apache.solr.handler.component.SearchComponent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * Solr SearchComponent – Redis bitmap store availability filter.
 *
 * How it works
 * ────────────
 * Each physical retail store has a Redis bitmap at key:
 *   store:{storeId}:availability
 *
 * Bit at offset equal to the product's numeric SKU is 1 if the product
 * is in-stock at that store, 0 otherwise.
 *
 * Query parameters
 * ────────────────
 *   store.id            (string)  – retail store ID to filter by.
 *                                   Omitting it disables the filter entirely.
 *   store.productIdField (string) – Solr field whose value is the numeric SKU
 *                                   (default: "sku").
 *   store.filterMode    (string)  – "filter" (default): remove unavailable docs
 *                                   "annotate": keep all docs, add storeAvailable field
 *
 * Example query:
 *   /select?q=laptop&store.id=1234&store.productIdField=sku&store.filterMode=filter
 */
public class RedisStoreAvailabilityComponent extends SearchComponent {

    private static final Logger log = LoggerFactory.getLogger(RedisStoreAvailabilityComponent.class);

    static final String PARAM_STORE_ID          = "store.id";
    static final String PARAM_PRODUCT_ID_FIELD  = "store.productIdField";
    static final String PARAM_FILTER_MODE       = "store.filterMode";
    static final String MODE_FILTER             = "filter";
    static final String MODE_ANNOTATE           = "annotate";
    static final String BITMAP_KEY_PREFIX       = "store:";
    static final String BITMAP_KEY_SUFFIX       = ":availability";

    private NamedList<?> initArgs;

    @Override
    public void init(NamedList<?> args) {
        this.initArgs = args;
        RedisConnectionManager.getInstance().init(args);
    }

    @Override
    public void prepare(ResponseBuilder rb) throws IOException {
        // Nothing to do at prepare time.
    }

    @Override
    public void process(ResponseBuilder rb) throws IOException {
        SolrParams params = rb.req.getParams();
        String storeId = params.get(PARAM_STORE_ID);

        if (storeId == null || storeId.isBlank()) {
            return;
        }

        String productIdField = params.get(PARAM_PRODUCT_ID_FIELD, "sku");
        String filterMode     = params.get(PARAM_FILTER_MODE, MODE_FILTER);
        boolean doFilter      = !MODE_ANNOTATE.equalsIgnoreCase(filterMode);

        SolrDocumentList results = rb.rsp.getResults();
        if (results == null || results.isEmpty()) {
            return;
        }

        String bitmapKey = BITMAP_KEY_PREFIX + storeId + BITMAP_KEY_SUFFIX;

        JedisPool pool = RedisConnectionManager.getInstance().getPool();
        try (Jedis jedis = pool.getResource()) {
            if (doFilter) {
                filterResults(results, jedis, bitmapKey, productIdField);
            } else {
                annotateResults(results, jedis, bitmapKey, productIdField);
            }
        } catch (Exception e) {
            log.error("Redis availability check failed for store {}; continuing without filter", storeId, e);
        }
    }

    private void filterResults(SolrDocumentList results,
                               Jedis jedis,
                               String bitmapKey,
                               String productIdField) {
        List<SolrDocument> kept = new ArrayList<>(results.size());
        for (SolrDocument doc : results) {
            long sku = extractSku(doc, productIdField);
            if (sku >= 0 && jedis.getbit(bitmapKey, sku)) {
                kept.add(doc);
            }
        }
        results.clear();
        results.addAll(kept);
        results.setNumFound(kept.size());
    }

    private void annotateResults(SolrDocumentList results,
                                 Jedis jedis,
                                 String bitmapKey,
                                 String productIdField) {
        for (SolrDocument doc : results) {
            long sku = extractSku(doc, productIdField);
            boolean available = sku >= 0 && jedis.getbit(bitmapKey, sku);
            doc.addField("storeAvailable", available);
        }
    }

    /**
     * Extract the numeric SKU from a Solr document field. Returns -1 on failure.
     */
    private long extractSku(SolrDocument doc, String field) {
        Object val = doc.getFieldValue(field);
        if (val == null) return -1;
        try {
            return Long.parseLong(val.toString());
        } catch (NumberFormatException e) {
            log.warn("Non-numeric SKU value '{}' in field '{}'; skipping bitmap check", val, field);
            return -1;
        }
    }

    @Override
    public String getDescription() {
        return "Redis Bitmap Store Availability Filter";
    }
}
